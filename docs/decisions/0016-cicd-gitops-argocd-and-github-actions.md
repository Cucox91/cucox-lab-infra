# ADR-0016 — CI/CD: GitHub Actions builds, Argo CD deploys (GitOps split-repo)

> **Status:** Proposed
> **Date:** 2026-05-02
> **Supersedes:** none
> **Superseded by:** none
> **Owner:** Raziel

## Context

The lab is heading into Phase 3 (real-app migration — see ARCH § 11). The
first migration target is the resume app (MERN; source currently lives at
`Apps Code/Resume App Updated/my-resume-app-code/` inside this repo). For
that to land cleanly we need an answer to a question Phase 1 and Phase 2
both deferred: **how does a `git push` on the operator workstation become
a running pod in the cluster, without manual `kubectl apply` from the
Mac Air every time?**

ARCH § 8.3 already speaks to one slice of this — *infrastructure* CI
(`terraform validate`, `terraform plan`, `ansible-lint`, `helm lint`)
runs on the Mac Mini in Phase 5, with no auto-apply. That's the
infra-side "humans push the button" promise and stays.

This ADR is about the *application* side, which has different shape:

1. **Application source code lives on GitHub** — separate repos (or
   subfolders) per app. Build artifacts are container images. Deploy
   targets are k8s manifests (Helm charts or kustomize overlays) in the
   cluster. Manual `kubectl apply` for every push does not scale beyond
   one app.
2. **The cluster lives behind cloudflared.** No public endpoints exist on
   the home network. Anything that pushes *into* the cluster from
   GitHub's network requires a publicly-reachable URL — which expands
   the attack surface in a direction `MEMORY.md → feedback_threat_priority_home_first.md`
   explicitly argues against. Anything that *pulls from* GitHub keeps
   network direction inward-out, matching the existing cloudflared
   posture.
3. **Image storage is unsolved.** The cluster has no in-cluster registry
   today. ARCH § 3.3.4 mentions a "Phase 4 registry mirror" but that's
   for *upstream* image caching, not for hosting our own builds.
4. **Secrets must remain SOPS-encrypted at rest in Git.** ADR-0003 +
   ADR-0008 are non-negotiable: any GitOps manifest repo must be safe to
   make public. That constrains how the cluster decrypts secrets at
   apply time.
5. **The repo structure today is mixed.** Infra (Terraform, Ansible,
   Helm values, runbooks, ADRs) and at least one app's source
   (`Apps Code/...`) live together. That's fine for now but does not
   scale to the four-app target in ARCH § 1.

The decision space spans four largely-independent axes:

| Axis | Choices |
|---|---|
| **Deploy model** | (a) Manual `kubectl/helm` from Mac Air. (b) Push from CI (GitHub Actions runs `helm upgrade` against the cluster). (c) **GitOps pull** — an in-cluster controller reconciles from Git. |
| **GitOps controller** | (a) **Argo CD**. (b) Flux. (c) None (stay manual). |
| **Image registry** | (a) **GHCR** (GitHub Container Registry). (b) Self-hosted Harbor in-cluster. (c) Docker Hub. |
| **CI runner** | (a) **GitHub-hosted runners** (`ubuntu-latest`). (b) Self-hosted runner inside the lab. (c) The Mac Mini in Phase 5 acts as a buildx + runner host. |

The choices below pick the conservative, lowest-blast-radius path for
each axis while leaving room for the Phase 5 multi-arch story to layer in
without rework.

## Decision

**1. Deploy model: GitOps pull with Argo CD.**

An `argocd` Deployment runs in the cluster (namespace: `argocd`,
PSA: `enforce=baseline`). Argo CD watches a separate **GitOps manifest
repo** (`cucox-lab-gitops`) on GitHub via a polling interval of 3 min
(default). When it sees the repo changed, it reconciles every Application
it manages against the cluster's current state and applies the diff.

No webhook is configured. Webhook-driven sync requires GitHub to call
into the cluster, which means a publicly-reachable URL through
cloudflared — exactly the kind of inbound surface
`feedback_threat_priority_home_first.md` argues against. 3-minute polling
is sufficient for non-emergency deploys; emergency rollbacks happen via
`argocd app sync` from the Mac Air, not via Git.

**2. GitOps controller: Argo CD over Flux.**

Argo wins on two grounds that matter for a single-operator learning lab:
the web UI is genuinely useful for understanding what is and isn't
synced (a homelab spends a lot of time in "wait, what state is the
cluster actually in" mode), and the project model maps cleanly to the
multi-app future of ARCH § 11. Flux's CLI-only / GitOps-purist posture is
philosophically cleaner but pays a price in observability that hurts more
than it helps at this scale. See *Alternatives* below.

**3. Two repos, not one.**

| Repo | Lives on GitHub as | Contains |
|---|---|---|
| **Source repo(s)** — one per app | `cucox91/resume-app`, `cucox91/<next-app>`, etc. | Application source code, Dockerfile, app-level CI (test, lint, build, push). |
| **GitOps manifest repo** | `cucox91/cucox-lab-gitops` | Helm values overlays, kustomize patches, Argo `Application` CRs, SOPS-encrypted secrets, the cluster's *intended* state. Public; the SOPS encryption per ADR-0008 is what makes that safe. |
| **This infra repo** (`cucox-lab-infra`) | unchanged | Terraform, Ansible, runbooks, ADRs, **bootstrap** Helm values. Continues as the infra source-of-truth. |

The current `Apps Code/Resume App Updated/my-resume-app-code/` subfolder
moves out of `cucox-lab-infra` into its own repo as part of the Phase 3
migration. Until then it stays put — this ADR doesn't force a Phase 3
prerequisite refactor; it documents the target.

**4. Image registry: GHCR (with Phase 4 fallback to Harbor).**

Use GHCR (`ghcr.io/cucox91/<app>:<tag>`). Free, supports private repos,
authenticates via a `GITHUB_TOKEN` already issued to each repo's CI.
Cluster pulls images via an `imagePullSecret` populated from a long-lived
Personal Access Token (PAT) with `read:packages` only — SOPS-encrypted
into the GitOps repo per ADR-0003.

A self-hosted Harbor in-cluster gets evaluated in Phase 4 as the
"registry mirror" ARCH § 3.3.4 anticipates. It would solve two real
problems by then: GHCR rate limits during a coordinated 4-app rebuild,
and the cluster going fully offline if GitHub has a bad day. Harbor
*also* supports image signing (Cosign) and vulnerability scanning
(Trivy) — both worth having, neither worth bringing in for one app.

**5. CI runner: GitHub-hosted (`ubuntu-latest`).**

Builds run on GitHub-hosted runners. Builds push to GHCR using
`actions/setup-buildx-action` and the workflow's `GITHUB_TOKEN`. After a
successful build, a follow-up step in the same workflow opens a PR
against the GitOps manifest repo bumping the relevant `image.tag`.
Merging that PR (manually, by Raziel) is what triggers Argo CD to
deploy.

GitHub-hosted runners never need credentials *into* the home network —
they push to GHCR (outbound from GitHub) and PR against the GitOps repo
(both stay on github.com). The cluster pulls from GitHub when it
syncs.

A self-hosted runner is rejected for Phase 3:

- It needs an outbound long-poll connection to GitHub — fine for the
  threat model — but it also needs cluster credentials if it's going to
  do anything useful, which is a counterargument to the whole "pull-not-
  push" stance Argo CD already gives us.
- Installing one inside the cluster requires a service account with
  enough authority to deploy, which is exactly the thing GitOps is
  supposed to remove.
- Phase 5's Mac Mini `buildx` host is the natural place to revisit
  self-hosted: ARM-cross-build matrix, faster builds, no minute caps.
  Not before.

**6. Image tagging strategy: immutable digests, no `:latest`.**

GitHub Actions builds produce two tags per push:

- A **semver** tag from the source repo's tag (`v1.4.0`) when the trigger
  is a Git tag push.
- A **commit-SHA** tag (`sha-3f2a91c`) on every push to `main`.

The GitOps repo always pins to **the digest** (`@sha256:...`), not the
human-readable tag. The PR Argo opens after a successful build sets:

```yaml
image:
  repository: ghcr.io/cucox91/resume-app
  tag: sha-3f2a91c
  digest: sha256:abc...
```

`tag` is for humans; `digest` is what Kubernetes actually pulls. This
prevents a class of deployment bug where someone pushes a new image
under the same tag and pods silently restart with different bits.
**Never** use `:latest` — Argo will treat it as "always synced" and the
cluster will drift invisibly.

**7. Secrets at rest in the GitOps repo: SOPS-encrypted, decrypted by an
in-cluster operator.**

The GitOps repo is intended to be safe to make public per ADR-0008.
That means every Secret manifest in it is SOPS-encrypted with the lab's
age recipient. An in-cluster decryption path is needed because Argo CD
itself doesn't speak SOPS. Two compatible options, decision deferred to
the Phase 3 Argo install runbook:

- **`argocd-vault-plugin`** + an in-cluster age key stored as an
  unencrypted Secret in the `argocd` namespace.
- **External Secrets Operator** with a SOPS / age provider.

Either works; both keep the on-disk-in-Git form encrypted and limit
plaintext to in-memory in the cluster. The age private key on the
cluster is a distinct keypair from the operator's age key on the Mac Air
— losing the cluster compromises only secrets that were already going to
land on the cluster, not the Mac Air's broader scope.

## Consequences

### Positive

- **Single source of intended state per app.** The GitOps repo is
  authoritative; "what is deployed?" is answered by `git log`, not by
  remembering what the operator typed three weeks ago.
- **Direction of trust matches threat model.** No inbound webhook means
  no public endpoint for CI. The cluster pulls from GitHub; nothing on
  GitHub's side ever has cluster credentials or a path inward.
- **Auditable rollbacks.** A bad deploy is reverted by reverting the
  GitOps PR, which Argo then reconciles back. Rollback history *is*
  Git history.
- **Per-app autonomy.** Each app's source repo can have its own CI
  conventions, tests, and reviewers. The GitOps repo is the integration
  point.
- **Bootstrap is reproducible.** Argo CD itself installs from a Helm
  chart in `cucox-lab-infra` (as the bootstrap layer); from there
  forward, Argo manages everything else. If the cluster is wiped, the
  recovery path is `helm install argo-cd → kubectl apply -f bootstrap-app.yaml
  → wait`. This is the GitOps "App of Apps" pattern.
- **GitHub-hosted runners cost zero in the public-repo case** and have
  generous free tiers in the private-repo case. No new homelab
  infrastructure to maintain.
- **Multi-arch story (Phase 5) layers in without redesign.** Add a
  `linux/arm64` build target to the existing `setup-buildx-action`
  invocation; the rest of the pipeline is unchanged.
- **Compliance with `feedback_threat_priority_home_first.md`.** No new
  inbound exposure. The image registry is on GHCR (Microsoft/GitHub
  property), not on the home network. The GitOps repo is on GitHub.
  Cluster reaches *out*; nothing reaches *in*.

### Negative

- **Three repos to keep coherent** (this infra repo, app source repos,
  GitOps repo) rather than one. The PR-from-CI step is what keeps them
  in sync; if that breaks, deployment silently stops happening (Argo
  syncs but nothing has changed). Phase 4 alerting will catch this; in
  Phase 3 we rely on the operator noticing.
- **Argo CD is a non-trivial dependency.** It's a Helm chart, a CRD set,
  a controller, a UI, and a Redis. ~500 MB of memory at idle. Adds an
  obvious target if the cluster is ever compromised — Argo's RBAC
  effectively *is* cluster RBAC for application namespaces. Mitigated by
  not exposing the Argo UI publicly (mgmt-VLAN-only via ingress, like
  Grafana per runbook 04 § "Why Grafana stays internal in Phase 2").
- **Polling latency.** A merged GitOps PR takes up to 3 minutes to
  start reconciling. Acceptable for a learning lab; would not be for
  production. Manual force-sync via `argocd app sync` exists for the
  rare urgency.
- **GHCR rate limits and vendor coupling.** GHCR has anonymous-pull
  rate limits (per IP) and authenticated-pull limits. A coordinated
  4-app deploy after a long offline window could brush against them.
  Phase 4 Harbor mirror solves this; Phase 3 lives with the risk.
- **The PAT used for `imagePullSecret` is a long-lived credential.**
  GitHub's per-repo `GITHUB_TOKEN` can't be used by the cluster (it's
  ephemeral, action-scoped). The fallback is a PAT with `read:packages`
  only, rotated annually. SOPS-encrypted, scoped to one purpose, but
  still a credential we'd rather not have.
- **Bootstrap-time chicken-and-egg.** The very first install of Argo CD
  itself can't be done by Argo CD. It is done by `helm install` from the
  Mac Air, in `cucox-lab-infra`. After that bootstrap, Argo manages
  Argo (via a self-managing Application). One-time complexity; well-
  documented in the Phase 3 runbook.

### Mitigations and second-order considerations

- **Argo's projects map to namespaces.** Each Argo `AppProject`
  constrains which namespaces and resource kinds its Applications can
  touch. The default project (`default`) gets restricted to nothing;
  every real Application belongs to a per-app project (e.g.,
  `resume-app-prod`) with explicit destinations. Limits blast radius if
  an Application manifest is poisoned.
- **PR review on the GitOps repo is the deploy gate.** The CI step that
  opens the image-bump PR does *not* auto-merge. A human (Raziel) merges
  after a quick visual diff. This preserves "humans push the button"
  from ARCH § 8.3 for the application path too — the button has just
  moved from `kubectl apply` on the laptop to "Merge PR" on github.com.
- **Drift detection.** Argo's `selfHeal: true` setting auto-reverts
  out-of-band changes (`kubectl edit` from the Mac Air during debugging,
  for example). Useful for production-shaped invariants; annoying for
  exploratory debugging. Default `selfHeal: false`, enable per-
  Application as workloads stabilize.
- **The infra repo's bootstrap layer.** A new Helm chart values file
  lands in `k8s/argocd/values.yaml`. The bootstrap App-of-Apps manifest
  lands in `k8s/argocd/bootstrap.yaml`. Both are deployed by the
  Phase 3 runbook with `helm install --values` once; Argo takes over
  from there.
- **Drag on the threat-priority second tier (cluster security).** Argo
  CD with cluster-admin is, in the limit, equivalent to handing the
  GitOps repo write key to the cluster. Per-project RBAC (above) and
  PR-review-on-merge (above) are the two compensating controls.

## Closes when

This ADR is "active" indefinitely; it sets the project's CI/CD shape.
Two future events would justify a successor:

1. **Phase 4 Harbor lands.** A successor ADR (likely `0019` or wherever
   the count is) records the registry move from GHCR to in-cluster
   Harbor and the imagePullSecret rotation. This ADR's GHCR choice is
   superseded for new apps; existing apps migrate on their next image
   bump.
2. **Self-hosted runner adoption in Phase 5.** When the Mac Mini joins
   as a `buildx` host, an addendum ADR records the matrix
   (GitHub-hosted for x86, self-hosted for arm64) and the runner's
   network posture.

If we *abandon* GitOps (e.g., Argo's operational cost outpaces its value
for one operator), this ADR is replaced by one explicitly choosing
manual deploys. That outcome is unlikely but not unthinkable for a
single-operator lab with three apps.

## Alternatives considered

- **Manual deploys: keep `helm upgrade` from the Mac Air.** Rejected.
  Works for one app, doesn't scale to four, loses audit trail (the
  cluster's state is in the operator's shell history), and offers no
  drift detection. The simplicity is real but the cost is paid every
  deploy forever.

- **GitHub Actions push directly into the cluster (no Argo / Flux).**
  GitHub Actions runs `helm upgrade` against the cluster's k8s API,
  reaching it through a kubeconfig stored as a GitHub repo secret.
  Rejected on threat-model grounds: it requires either a publicly-
  reachable k8s API endpoint (deeply unwanted) or a self-hosted runner
  inside the cluster with cluster-admin (which defeats the
  separation-of-concerns the ADR is trying to create). Push-mode
  deploys also don't get drift detection or Git-based rollback for
  free — both of which are the main wins of the GitOps split.

- **Flux instead of Argo CD.** Flux is the philosophically cleaner
  GitOps controller: smaller surface area, no UI to defend, better
  Helm-source semantics, GitOps-Toolkit modular CRDs. Rejected because
  the Argo UI is genuinely load-bearing for a one-operator learning lab
  — knowing at a glance which Applications are out of sync, which last
  sync failed and why, which CRDs Argo is managing, is worth materially
  more than the smaller surface area. Flux gets reconsidered in Phase 4
  if Argo's RBAC sprawl becomes painful.

- **Docker Hub as the registry.** Rejected: stricter rate limits than
  GHCR, no integration with GitHub auth (separate credentials to
  rotate), and pull-through cost paid in every deploy. GHCR is on the
  same identity boundary as the source repos; one less thing to
  authenticate against.

- **Self-hosted Harbor in Phase 3 (skip GHCR entirely).** Rejected as
  premature. Harbor solves real problems but adds a stateful service
  with backup/restore requirements before the Phase 4 storage layer
  (Longhorn) is in place. Going Harbor-first ties the registry's
  durability to the local-path PV pinned to one node — the exact
  fragility ARCH § 5.3 acknowledges as a Phase-1/2 limitation.

- **One mega-repo: app source + infra + GitOps in `cucox-lab-infra`.**
  Rejected. The current "Apps Code in subfolder" arrangement was a
  Phase 1 expedient and is already showing strain (the `node_modules`
  tree from the resume app dominates `git ls-files` output). More
  importantly, mixing per-app autonomy (an app's CI fails its own
  tests) with infra-wide cadence (the infra repo's PRs are about the
  whole lab) creates review-overhead that doesn't pay off. Two-repo
  split is one more repo to clone, but a much clearer ownership story.

- **Push-mode CI with a Tailscale-only runner.** A self-hosted runner
  inside the lab, reachable from GitHub Actions only over the tailnet,
  could in principle do `helm upgrade` against a Tailscale-only k8s API
  endpoint. Rejected: the complexity of the auth path (tailnet ACL +
  k8s RBAC + GitHub federated identity) is materially higher than the
  Argo CD pull model, and the resulting system is harder to reason
  about in a security review. The pull model wins on simplicity.

## References

- [ARCHITECTURE.md § 1](../../ARCHITECTURE.md) — the four-app target
  this ADR is sized for.
- [ARCHITECTURE.md § 8.2 / 8.3](../../ARCHITECTURE.md) — the existing
  repo layout and infra-CI plan; this ADR is the application-CI
  counterpart.
- [ARCHITECTURE.md § 11 — Phase 3](../../ARCHITECTURE.md) — the
  application-migration phase this ADR enables.
- [ADR-0003](./0003-secrets-sops-age.md) — SOPS/age scheme; required
  shape of the GitOps repo's secrets.
- [ADR-0008](./0008-public-repo-sops-gitleaks.md) — public-repo posture
  the GitOps repo follows.
- [Runbook 04 § "Why Grafana stays internal in Phase 2"](../runbooks/04-phase2-observability.md) —
  the same mgmt-VLAN-only pattern Argo CD's UI will follow.
- `MEMORY.md → feedback_threat_priority_home_first.md` — the priority
  order this ADR's no-inbound-webhook decision respects.
- `MEMORY.md → feedback_security_over_speed.md` — the conservative
  posture that argued against webhook-driven sync.
- Future runbook 07 (TBD) — the Phase 3 Argo CD bootstrap (App-of-Apps,
  bootstrap secret, first Application). To be authored alongside the
  resume app migration.
