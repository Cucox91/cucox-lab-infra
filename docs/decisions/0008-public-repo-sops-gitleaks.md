# ADR-0008 — Public GitHub repository with SOPS + gitleaks hygiene

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-25 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

The `cucox-lab-infra` repository contains the entire design and operational
configuration of the lab — Terraform for VMs, Ansible roles, Helm values,
runbooks, ADRs, and (in encrypted form) secrets. We need to decide whether
to publish it.

The lab supports two stated goals:

1. Self-host real applications away from Azure (production traffic, real
   secrets, real consequences if compromised).
2. Serve as a learning artifact and **portfolio surface for senior IC roles**
   — IC5 trajectory targeting FAANG SRE / HPC / SpaceX-style infra teams.
   For senior infra-adjacent positions, hiring loops routinely review
   GitHub; a polished public infrastructure repo is one of the highest-
   signal portfolio artifacts available.

The decision must balance the portfolio value of public exposure against
the operational risk of secret leakage and the cost of ongoing hygiene.

## Decision

The repository is **public on GitHub from day one**.

- All secrets in the repo are encrypted with **SOPS + age** before commit.
- A pre-commit `gitleaks` hook blocks any plaintext credential pattern.
- A small set of "keys-to-the-kingdom" credentials are kept **out of the
  repo entirely**, even encrypted (see § "What stays out of the repo").
- A project-local Git identity prevents personal-email leakage.

## Rationale

### Why public is safe

- All in-cluster IPs (`10.10.x.x`) are RFC1918 private. Exposing the
  topology gives no attacker leverage; the perimeter is enforced by the
  Cloudflare Tunnel and the UCG-Max firewall, not by obscurity.
- Every tool in the stack (Proxmox, k3s, Cilium, MetalLB, Cloudflared,
  SOPS, age) is open-source and broadly documented; the lab's design
  exposes nothing not already exposed by upstream documentation.
- Industry precedent: GitLab, HashiCorp, 18F, and many DevOps-mature teams
  publish their infrastructure-as-code openly with strong hygiene.

### Why public is valuable

- Recruiters and hiring loops at senior infra-adjacent roles routinely
  review GitHub. A coherent, documented, multi-component lab is a stronger
  signal than any resume bullet.
- "Strangers will read this" is a forcing function for higher-quality
  ADRs, runbooks, and commit messages.
- The repo becomes a citation in interviews ("walk me through ADR-0002")
  and a substrate for blog posts and writeups.
- Easier collaboration with future contributors and easier to point LLM
  tooling (Claude, others) at the repo for review.

### What stays out of the repo

The following are never committed, even encrypted:

- `cloudflared` tunnel credentials JSON — this file *is* the keys to all
  external traffic into the lab; it lives only on `lab-edge01` and a
  1Password backup.
- Cloudflare **Global API Key** — never used. All Cloudflare automation
  uses **scoped API tokens** with minimum permissions per use case.
- GoDaddy registrar credentials — registrar control is high-leverage and
  out of scope for IaC.
- The age **private key** (`~/.config/sops/age/keys.txt`) — kept locally
  on the operator machine and backed up to 1Password.
- Personal/work email addresses in commit metadata — see hygiene below.
- Any plaintext password, regardless of risk level — the rule is
  "encrypt-or-don't-commit" with no exceptions.

## Hygiene controls

### In-repo

- **`.sops.yaml`** at repo root configures path-based encryption:
  `*.secrets.yml`, `**/secrets/*.yaml`, every k8s `Secret` manifest,
  `cloudflared/creds.*`, `**/credentials.json`.
- **`.pre-commit-config.yaml`** runs on every commit:
  - `gitleaks detect` — blocks plaintext credential patterns (AWS keys,
    GitHub tokens, generic high-entropy strings, etc.).
  - `sops-pre-commit` — refuses unencrypted commits to protected paths.
  - `terraform fmt`, `tflint`.
  - `ansible-lint`, `yamllint`.
- **`.gitignore`** excludes local cache files (`.terraform/`,
  `*.tfstate*`, `.ansible/`, `.kube/`, age keys at any path).

### Operator machine

- Project-local Git identity:
  ```
  git config user.email "raziel@cucox.dev"
  git config user.name  "Raziel (Cucox Lab)"
  ```
- `pre-commit install` run once after clone; hooks enforced locally.
- age private key on encrypted disk; backed up via 1Password.

### GitHub-side

- **Branch protection on `main`**: require PR (self-merge OK for solo work,
  but the PR pattern enforces diff review and CI runs).
- **Secret Scanning** enabled (GitHub-side belt-and-suspenders against
  hygiene gaps).
- **Dependabot** enabled for Terraform providers, GitHub Actions, Helm
  charts.
- **`SECURITY.md`** at repo root with a disclosure email
  (`security@cucox.dev` or similar) and a clear "this is a personal lab,
  best-effort response" expectation.

## Consequences

### Positive

- High-signal portfolio surface aligned with IC5 career goals.
- Discipline pressure improves documentation quality.
- Easier knowledge transfer to future collaborators or LLM tools.
- Public ADR/runbook content can be linked from blog posts and the
  resume site at `cucox.me`.

### Negative / risks

- **Secret leak risk increases.** Mitigated by SOPS + gitleaks + scoped
  tokens + a "never commit unencrypted secrets" rule. Risk is non-zero.
- **History contains everything.** A leaked secret in commit history
  requires `git filter-repo` + force-push + token rotation, not just a
  follow-up commit. Procedure belongs in a future runbook.
- **Public bug-bounty / drive-by reports.** `SECURITY.md` sets
  expectations.
- **Personal info in old commits / branch names** requires a one-time
  audit before going public.

### Reversal cost

- **Public → Private**: one click on GitHub. Trivial.
- **Private → Public**: requires a full audit of every commit, branch,
  and tag. Going public from day one keeps this audit cost low because
  every commit is made under public-aware hygiene.

## Implementation checklist

- [ ] `brew install gitleaks pre-commit sops age`
- [ ] `age-keygen -o ~/.config/sops/age/keys.txt` (already in Phase 0)
- [ ] Add `.sops.yaml` to repo root with the age recipient
- [ ] Add `.pre-commit-config.yaml`; run `pre-commit install`
- [ ] Configure project-local Git identity
- [ ] Audit existing commits (this repo is fresh; minimal)
- [ ] Create GitHub repo `cucox-lab-infra` (public)
- [ ] Push `main`
- [ ] Enable Branch Protection, Secret Scanning, Dependabot
- [ ] Add `SECURITY.md`
- [ ] Add the public repo URL to `cucox.me` resume site
