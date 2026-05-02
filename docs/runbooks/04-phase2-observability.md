# Runbook 04 — Phase 2: Observability (kube-prometheus-stack + Grafana)

> **Goal:** End the runbook with `kube-prometheus-stack` running in the
> `monitoring` namespace, scraping the cluster control-plane,
> `node_exporter` on every node, `kube-state-metrics`, the
> `ingress-nginx` controller via its ServiceMonitor, and the
> out-of-cluster `cloudflared` daemon on `lab-edge01` via a static
> Prometheus scrape target. Grafana is reachable from the operator
> workstation at `https://grafana.lab.cucox.local/` (resolved via Mac Air
> `/etc/hosts` → `10.10.20.50`), with the three Cucox-Lab landing
> dashboards seeded per ARCH § 7.1.
>
> **No public hostname is exposed** — Grafana is mgmt-VLAN-only. The
> Cloudflare Access bootstrap that protects publicly-exposed admin UIs
> belongs to runbook 05 (or a Phase 3 follow-up), not here. ARCH § 6.2
> still applies in spirit; this runbook stops short of the public side.
>
> **Estimated time:** 2 hours, of which the kube-prometheus-stack
> install + initial scrape settle is the longest single block (~30 min).
>
> **Operator:** Raziel, Mac Air on `CucoxLab-Mgmt` (VLAN 10).

---

## What this runbook implements

| ARCHITECTURE.md ref | Implemented here |
|---|---|
| § 7.1 — Day-1 stack | `kube-prometheus-stack` Helm chart in `monitoring` namespace. Prometheus 1 replica, 30d retention on `local-path` PV pinned to `lab-wk01`. Grafana 1 replica with three seeded dashboards. `node_exporter` DaemonSet across all 5 nodes. `kube-state-metrics` with default ServiceMonitors. |
| § 5.4 — Ingress | `ingress-nginx`'s ServiceMonitor (currently `enabled: false` per runbook 02 § 6.1) is flipped to `enabled: true`. Controller `metrics.enabled: true` was pinned in advance specifically for this; no Helm chart re-install of ingress-nginx required. |
| § 6.1 — `cloudflared` topology | `cloudflared` lives outside the cluster on `lab-edge01` (dmz VLAN). A ServiceMonitor doesn't apply; instead, an `additionalScrapeConfigs` entry under `prometheus.prometheusSpec` adds a static target `10.10.30.21:2000`. |
| § 3.3.1 — Inter-VLAN | One new allow rule on the UCG-Max: `cluster (10.10.20.0/24) → dmz (10.10.30.21):tcp/2000`. This is a deviation from ARCH § 3.3.1's current matrix (which only allows `cluster → dmz: tcp/443 to ingress, tcp/7844 to cloudflared`). Documented as **ADR-0015** so the deviation is traceable. |
| § 3.3.5 — Stateful return | The existing `dmz → cluster: Established, Related` rule (added in runbook 03 § 3.2) covers the return half of the new scrape flow; verified explicitly in Step 3.4, not assumed. |
| § 7.2 — Future additions | Alertmanager is **disabled** in chart values (deferred per ARCH § 7.2). Loki + Tempo are not part of Phase 2. |
| § 9 — Secrets | Grafana admin password is generated locally and SOPS-encrypted into `ansible/group_vars/monitoring/grafana.enc.yaml`. Helm consumes it via `--set-file` from on-the-fly decryption — plaintext never lands on disk. |

What this runbook does **not** do: expose Grafana publicly via Cloudflare
Tunnel (deferred — see § "Why Grafana stays internal in Phase 2" below),
add Cloudflare Access policies (Phase 3 follow-up gated on the first
public hostname in runbook 05), install Loki / Tempo / Alertmanager
(ARCH § 7.2), or build alert rules.

---

## Prerequisites

- **Runbook 02 complete.** `kubectl get nodes` shows 5 Ready, ingress-nginx
  pinned to `10.10.20.50`, `controller.metrics.enabled: true` already
  set in `k8s/ingress-nginx/values.yaml` (verify):

  ```sh
  grep -A3 'metrics:' "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/k8s/ingress-nginx/values.yaml"
  # Expect: metrics.enabled true, serviceMonitor.enabled false (we flip the latter in Step 5).
  ```

- **Runbook 03 complete.** `cloudflared` HEALTHY on `lab-edge01`,
  systemd unit running as the `cloudflared` user, metrics endpoint
  currently bound to `127.0.0.1:2000` per
  `cloudflared/config.yaml.tmpl`. We rebind it to a routable interface
  in Step 6.1.

  ```sh
  ssh ubuntu@10.10.30.21 'sudo systemctl is-active cloudflared && curl -sI --max-time 3 http://127.0.0.1:2000/metrics | head -1'
  # Expect: active; HTTP/1.1 200 OK
  ```

- **Mac Air has `kubectl` and `helm`** (installed in runbook 02).
  Re-confirm:

  ```sh
  kubectl version --client; helm version
  ```

- **Mac Air age private key** at `~/.config/sops/age/keys.txt`. (Same
  one used for runbook 02 § Step 1 and runbook 03 § Step 1.3.)

- **`.sops.yaml` already matches `*.enc.yaml`** (added in runbook 02).
  No new creation rules needed for this runbook.

- **`KUBECONFIG`** is exported and points at `~/.kube/cucox-lab.yaml`
  (per runbook 02 § Step 3.2). Verify:

  ```sh
  kubectl config current-context; kubectl get nodes -o wide
  ```

  All five nodes Ready. If not, stop and fix runbook 02 first — this
  runbook will deploy DaemonSet workloads on every node and a stuck
  node will mask itself as a kube-prometheus-stack scrape gap.

- **Worker disk headroom on `lab-wk01`.** Prometheus PV is pinned to
  this node (Step 4); local-path PVs are node-bound per ARCH § 5.3, so
  pinning is not optional, it's how we make scheduling deterministic.

  ```sh
  ssh ubuntu@10.10.20.31 'df -h /var/lib/rancher/k3s/storage 2>/dev/null || df -h /'
  # Expect ≥ 60 GB free on the path k3s/local-path uses for PVs.
  ```

  If `lab-wk01` doesn't have ≥ 60 GB free, either (a) reduce retention
  in Step 4's values to fit, or (b) pin Prometheus to `lab-wk02`
  instead and update Step 4's `nodeSelector` accordingly. Don't let
  Prometheus end up unscheduled at 3am with `Insufficient ephemeral-storage`.

---

## Why Grafana stays internal in Phase 2

The architectural intent in ARCH § 6.2 is "Cloudflare Access in front
of any admin UI". Two paths to honor that:

**Conservative (this runbook):** Grafana stays mgmt-VLAN-only.
Hostname `grafana.lab.cucox.local` resolves on the Mac Air via
`/etc/hosts` to the ingress VIP `10.10.20.50`. No Cloudflare DNS
record. No tunnel hostname route. No Access policy. The admin UI is
unreachable from the public internet by construction.

**Faster (deferred):** Add `grafana.cucox.me` to the tunnel and the
Cloudflare zone, gated by an Access policy. Lights up observability
"with eyes from anywhere" earlier — but expands the public surface
before the platform has been internally exercised.

Per the standing security-over-speed posture (memory:
`feedback_security_over_speed.md`), this runbook takes the conservative
path. The work to publish Grafana publicly behind Access is recorded as
a follow-up in § Hand-off and lands naturally **after** runbook 05's
`cucox.me` cutover, when:

1. The Cloudflare zone is active (not Pending).
2. The first public hostname has been validated end-to-end on a low-
   stakes target (`cucox.me`) before we point the admin UI at the same
   pipe.
3. The Cloudflare Zero Trust org has been bootstrapped with an IdP and
   default deny.

If you want to override this and bring Grafana public in this runbook,
flag it before Step 7 and we re-scope. Don't graft it on after
the fact — Access policy bootstrap is its own multi-step exercise.

---

## Scope of one observability bring-up

For the `kube-prometheus-stack` deployment plus the cloudflared static
scrape, this runbook touches:

1. Decisions to lock (Step 0).
2. ADR-0015 stub for the new firewall allow (Step 1.0 — written before
   the rule is added so the deviation is reasoned about, not retrofit).
3. Firewall preflight + new allow on the UCG-Max: `cluster → dmz:2000`
   plus return-traffic verification (Step 1).
4. `monitoring` namespace creation (Step 2).
5. Grafana admin password generation + SOPS seal (Step 3).
6. kube-prometheus-stack values + install (Step 4).
7. ServiceMonitor flip on ingress-nginx (Step 5).
8. cloudflared metrics rebind from loopback to the dmz interface, plus
   the `additionalScrapeConfigs` entry (Step 6).
9. Internal DNS for Grafana on the Mac Air (Step 7.1) + Ingress
   resource (Step 7.2) + smoke-test login (Step 7.3).
10. Three seeded dashboards (Step 8).
11. Snapshot, document, file edits (Step 9).

Each numbered step has an explicit **Decision gate** before the next.
Do not advance on intuition.

---

## Step 0 — Decisions to lock

Lock these values now so the rest is mechanical.

| Variable | Value | Source |
|---|---|---|
| Namespace | `monitoring` | ARCH § 10 (k8s namespaces, role-named) |
| Helm chart | `prometheus-community/kube-prometheus-stack` | ARCH § 7.1 |
| Chart version | `84.5.0` (current stable as of 2026-05-01; supports k8s 1.30+, ships prometheus-operator v0.90.1) | upstream Helm repo |
| Prometheus replicas | 1 | ARCH § 7.1 |
| Prometheus retention | `30d` | ARCH § 7.1 |
| Prometheus PVC | `50Gi`, `storageClassName: local-path` | ARCH § 5.3 + § 7.1 |
| Prometheus node pin | `lab-wk01` (via `nodeSelector`) | local-path PV is node-bound; pin so scheduling is deterministic |
| Grafana replicas | 1 | ARCH § 7.1 |
| Grafana hostname (internal) | `grafana.lab.cucox.local` | ARCH § 5.5 (`*.lab.cucox.local`) |
| Grafana hostname → IP (Mac Air) | `10.10.20.50` (ingress VIP) | runbook 02 § 6.1 |
| Alertmanager | **disabled** in chart values | ARCH § 7.2 |
| ingress-nginx ServiceMonitor | flip `enabled: false` → `true` | runbook 02 § 6.1 staged this |
| cloudflared metrics bind | `10.10.30.21:2000` (was `127.0.0.1:2000`) | rebind to dmz interface only, not `0.0.0.0` — defense in depth |
| New firewall allow | `cluster (10.10.20.0/24) → dmz (10.10.30.21):tcp/2000` | new (this runbook); ADR-0015 |
| Grafana admin user | `admin` | chart default |
| Grafana admin password | generated, SOPS-sealed | this runbook § Step 3 |

> **Why pin Prometheus to a specific worker?** `local-path-provisioner`
> creates PVs that bind to the node where the PVC was first scheduled.
> If the Prometheus pod ever restarts onto a different node, the PV
> goes orphan and the new pod is unschedulable. Two ways to avoid that:
> (a) `nodeSelector` to a known node, or (b) move to a replicated
> storage class (Longhorn, Phase 4). Phase 2 takes (a). When Longhorn
> lands in Phase 4, drop the `nodeSelector` and migrate the PVC.
>
> **Why bind cloudflared metrics to `10.10.30.21:2000` not `0.0.0.0:2000`?**
> The dmz VM has only one routable interface, so functionally these are
> identical today. But `0.0.0.0` listens on every future interface too —
> if we ever add a second NIC (e.g. for backup ingest or a future ARM
> worker bridge), the metrics endpoint silently follows. Specific-IP
> binding makes the exposure surface explicit; the firewall rule is
> the second layer. Belt and suspenders.

---

## Step 1 — Firewall preflight + new `cluster → dmz:2000` allow

The one new flow this runbook needs through the UCG-Max is a Prometheus
pod (running on a cluster-VLAN node, source IP after Cilium SNAT =
node IP in `10.10.20.0/24`) reaching `10.10.30.21:2000`. Default deny
is in force; this rule has to be added explicitly.

### 1.0 — Pre-write ADR-0015 stub

The deviation from ARCH § 3.3.1's matrix is small but real: § 3.3.1
listed only `tcp/443` and `tcp/7844` for `cluster → dmz`. Adding
`tcp/2000` widens it. Per the ARCHITECTURE.md preamble, anything that
materially changes the firewall posture gets an ADR. Write the stub
**before** clicking the rule into UniFi, so the rationale is committed
to the repo before the rule is committed to the gateway.

Create `docs/decisions/0015-cluster-dmz-2000-prometheus-cloudflared.md`:

```markdown
# ADR-0015 — Open `cluster → dmz: tcp/2000` for Prometheus → cloudflared metrics scrape

- **Status:** Active (deviation, time-boxed)
- **Date:** 2026-05-01
- **Supersedes:** none
- **Superseded by:** none

## Context

ARCH § 3.3.1's `cluster → dmz` row currently allows only `tcp/443 to
ingress` and `tcp/7844 to cloudflared`. Phase 2 observability needs
Prometheus (in-cluster) to scrape the cloudflared metrics endpoint on
`lab-edge01` (out-of-cluster, dmz VLAN). The endpoint speaks plain
HTTP on port 2000.

A ServiceMonitor doesn't apply because cloudflared is not a k8s Service
— it's a systemd daemon on a non-cluster VM. The clean path is a
Prometheus `additionalScrapeConfigs` static target. The clean firewall
path is one allow rule, narrowly scoped.

## Decision

Add a single allow rule to the UCG-Max:

- **Cell:** `Lab-Cluster → Lab-DMZ`
- **Source:** `10.10.20.0/24`
- **Destination:** `10.10.30.21/32`
- **Protocol:** `tcp`
- **Port:** `2000`
- **Position:** above any catch-all `Block All` in the cell.

The existing `dmz → cluster: Established, Related` rule (added in
runbook 03 § 3.2) covers the return half — conntrack matches on flow
state, not port, so the new flow's responses are already permitted.

Verify, do not assume.

## Consequences

- Adds 1 line to ARCH § 3.3.1.
- cloudflared metrics endpoint moves from `127.0.0.1:2000` to
  `10.10.30.21:2000` so the scrape can reach it.
- The endpoint stays unauthenticated. Risk is bounded by:
  - Source restricted to cluster VLAN at the gateway.
  - cloudflared exposes only operational metrics, no secrets.
  - dmz egress to the public internet does not include port 2000.

## Closes when

Phase 5 moves cloudflared into the cluster as a Deployment (ARCH § 6.1
future). At that point the firewall rule becomes obsolete and gets
removed in the same PR that lands the in-cluster Deployment.

## Diagram impact

Update `docs/diagrams/cucox-lab-architecture.drawio` to add the
`cluster → dmz:2000` arrow alongside the existing `:443` and `:7844`
arrows. Re-export SVG.
```

### 1.1 — Add the allow rule on the UCG-Max

UCG-Max UI → **Settings → Security → Zone Matrix → Lab-Cluster → Lab-DMZ
cell → Manage Policies → Create New Rule**.

| Field | Value |
|---|---|
| Name | `cluster→edge01:2000 (prom-scrape-cloudflared)` |
| Action | Accept |
| Source — Type | Network |
| Source — Network | `Lab-Cluster` |
| Source — IP | `10.10.20.0/24` |
| Destination — Type | IP |
| Destination — IP | `10.10.30.21/32` |
| Protocol | TCP |
| Destination Port | `2000` |
| Match State | (leave default — new connections) |
| Rule Order | **above** any `Block All` in this cell. Confirm by reading the rule list (not the matrix display) and noting IDs. |

Save. Wait for **"Provision Successful"** (30–60 s). Per `MEMORY.md →
unifi_zone_firewall_gotchas.md`, do not retest before provision lands —
you'll either fool yourself with stale state or, worse, blame the
daemon for a not-yet-applied rule.

### 1.2 — Verify rule order in the cell

After provision, open the cell again, switch to the rule-list view (not
the Zone Matrix summary), confirm:

- The new `cluster→edge01:2000` allow has a **lower ID** than any
  catch-all `Block All` in the cell.
- The two existing allows (`tcp/443 to 10.10.20.50` and `tcp/7844 to
  10.10.30.21`) from runbook 03 are still present and still above any
  `Block All`.

Screenshot the rule list and save it next to the GoDaddy zone baseline
under `~/Documents/cucox-lab-archive/firewall-snapshots/` for
operational history. (Outside the repo by design.)

### 1.3 — Smoke-test the new allow (without yet rebinding cloudflared)

The cloudflared daemon is still bound to `127.0.0.1:2000` at this
point — Step 6.1 is what rebinds it. So this smoke test runs against
**a temporary listener** on `lab-edge01:2000`, just to prove the
firewall rule is in place. Don't skip it; the firewall change has to
be verified independently of the cloudflared rebind.

On `lab-edge01`, start a temporary `nc` listener on port 2000:

```sh
ssh ubuntu@10.10.30.21 'sudo systemctl stop cloudflared; nc -l -p 2000 0.0.0.0'
# Leave this running. Will be torn down in 1.5.
```

> Stopping `cloudflared` first frees port 2000 from the in-process
> loopback bind. We restart it in 1.5 with the original config (Step
> 6.1 does the actual rebind).

From the Mac Air, in a **separate terminal**, exec a temporary debug
pod into the cluster and probe:

```sh
kubectl run fw-probe --rm -it --restart=Never --image=nicolaka/netshoot -- bash -lc 'nc -zv 10.10.30.21 2000; echo "exit=$?"'
# Expect: "Connection to 10.10.30.21 2000 port [tcp/*] succeeded!" exit=0
```

If the connection succeeds, the firewall allow + return rule combo is
correct. If it hangs, suspect either (a) the new allow is below
`Block All` in ID order, or (b) `dmz → cluster: Established, Related`
is somehow narrower than expected (it shouldn't be — it's stateful, not
port-scoped — but verify anyway by reading the rule).

If the connection is refused immediately (TCP RST), `nc -l` died. Check
the ssh terminal where you started it.

### 1.4 — Tear down the temporary probe

On the ssh session running `nc`: **Ctrl-C** to stop it.

Then restart cloudflared on its old config (still `127.0.0.1:2000` —
Step 6.1 rebinds later):

```sh
ssh ubuntu@10.10.30.21 'sudo systemctl start cloudflared && sleep 2 && sudo systemctl is-active cloudflared'
# Expect: active
```

Confirm tunnel is HEALTHY in the Cloudflare dashboard before continuing
(Networks → Tunnels → cucox-lab-prod → Status). The tunnel should
re-register within ~10s.

### Decision gate before Step 2

- [ ] `docs/decisions/0015-cluster-dmz-2000-prometheus-cloudflared.md`
      exists with the stub above.
- [ ] UCG-Max has the new allow with the right source/dest/port and a
      lower ID than any `Block All` in `Lab-Cluster → Lab-DMZ`.
- [ ] Provision is complete ("Provision Successful" toast cleared).
- [ ] `kubectl run fw-probe ...` connected to `10.10.30.21:2000`
      against the temporary `nc` listener. Exit code 0.
- [ ] `nc` listener torn down; `cloudflared` is `active` again on
      `lab-edge01`; tunnel still HEALTHY in dashboard.
- [ ] No other firewall cells were touched in this step (verify
      visually — easy to misclick into `Lab-Cluster → Gateway`).

If any box is unchecked, do not advance.

---

## Step 2 — Create the `monitoring` namespace

```sh
kubectl create namespace monitoring
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=restricted
```

> **PSA-level note** (lesson from the 2026-05-01 first execution).
> The first draft of this runbook set `enforce=baseline`, expecting
> that to admit `node-exporter`. **It does not.** Per the actual Pod
> Security Standards spec, `baseline` forbids `hostNetwork`,
> `hostPID`, `hostPath` volumes, and unprivileged `hostPort`s — every
> one of which `node-exporter` legitimately needs to scrape kernel
> metrics. With `enforce=baseline` the DaemonSet's pods get rejected
> with `violates PodSecurity "baseline:latest"` and the DS sits at
> `CURRENT 0` indefinitely (the only signal is in events, not in
> `kubectl get pods`).
>
> The right level for an observability namespace running
> node-exporter is `enforce=privileged`. The
> `warn=restricted` label is still load-bearing — it makes the
> cluster *print a warning* when something in this namespace asks for
> more than `restricted` allows, which is the operator-visible signal
> we want for new workloads. PSA's job here is to flag deviations,
> not to fight legitimate privileged workloads.
>
> The threat-priority story is unchanged: node-exporter is read-only
> kernel-metric scrape on the cluster-VLAN node IP. The cluster→Default-LAN
> deny in ARCH § 3.3.1 holds at the gateway regardless of pod privilege
> level, so the priority-1 (home network) blast radius is bounded by
> the firewall, not by PSA. See `MEMORY.md → psa_node_exporter_baseline_blocks.md`
> for the full incident.

Verify:

```sh
kubectl get namespace monitoring -o jsonpath='{.metadata.labels}' ; echo
```

---

## Step 3 — Generate and SOPS-seal the Grafana admin password

Same discipline as runbook 02 § Step 1: leading-space prefix to skip
shell history; pipe directly into sops; no plaintext on disk.

```sh
 cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
 mkdir -p ansible/group_vars/monitoring

 # 32-byte url-safe base64 password — pipe directly into sops, never to disk.
 printf 'grafana_admin_password: %s\n' "$(openssl rand -base64 24 | tr -d '\n=' | tr '/+' '_-' )" | sops --encrypt --filename-override ansible/group_vars/monitoring/grafana.enc.yaml --input-type yaml --output-type yaml /dev/stdin > ansible/group_vars/monitoring/grafana.enc.yaml

 head -3 ansible/group_vars/monitoring/grafana.enc.yaml   # expect a `sops:` block
 wc -c ansible/group_vars/monitoring/grafana.enc.yaml      # expect ~1KB, NOT 0
```

If `wc -c` shows 0, sops failed silently (same trap as runbook 03 §
2.4). Re-check the `.sops.yaml` rule for `*.enc.yaml`.

> The url-safe base64 transform (`tr '/+' '_-'`) avoids the `/` and `+`
> characters that confuse some Helm `--set` parsers. Stripping `=`
> padding keeps the value paste-clean.

To read the password at runtime, always pipe — never assign to a shell
variable that ends up in `ps -ef`:

```sh
 sops --decrypt ansible/group_vars/monitoring/grafana.enc.yaml | yq -r .grafana_admin_password
```

### Decision gate before Step 4

- [ ] `ansible/group_vars/monitoring/grafana.enc.yaml` is a sealed sops
      file (`head -3` shows `sops:` metadata).
- [ ] The password decrypts cleanly.
- [ ] Plaintext is **nowhere on disk**: `history | grep grafana_admin`
      returns nothing relevant.

---

## Step 4 — Install kube-prometheus-stack

### 4.1 Add the chart

```sh
helm repo add prometheus-community "https://prometheus-community.github.io/helm-charts"
helm repo update
helm search repo prometheus-community/kube-prometheus-stack --versions | head -5
# Confirm 84.5.0 (or the latest stable in the 84.x line) is available.
# Originally drafted at 65.5.0; on first execution (2026-05-01) the
# chart had moved to 84.x — major-version jump. Schema diff against
# the runbook's values block confirmed: every field used is present
# at the same path in 84.5.0 (`crds:`, `serviceMonitorSelectorNilUsesHelmValues`,
# `additionalScrapeConfigs`, the four `kube*` toggles, Grafana
# `adminPassword`, `prometheus.prometheusSpec.nodeSelector`). Bumping
# to 84.5.0 was a one-line pin change, not a rewrite.
#
# If a future re-run finds the chart has moved on past 84.x, repeat
# the same diff: `helm show values .../kube-prometheus-stack --version
# <new> | grep -nE '<the-fields-from-Step-4.2>'`. Bump on clean diff;
# pause and review on dirty diff.
```

### 4.2 Values file

Create `k8s/kube-prometheus-stack/values.yaml`:

```yaml
# k8s/kube-prometheus-stack/values.yaml — Cucox Lab Phase 2 observability.
# See ARCHITECTURE.md § 7.1 and runbook 04.

# ---------------------------------------------------------------- alerts
alertmanager:
  enabled: false                       # ARCH § 7.2 — deferred to Phase 4

# ---------------------------------------------------------------- prom
prometheus:
  prometheusSpec:
    replicas: 1
    retention: 30d
    retentionSize: 45GB                # leave headroom under the 50Gi PVC

    # Pin to lab-wk01 — local-path PVs are node-bound (ARCH § 5.3).
    nodeSelector:
      kubernetes.io/hostname: lab-wk01

    # Don't filter ServiceMonitors by Helm release label — let any
    # ServiceMonitor in any namespace match. This is what allows
    # ingress-nginx's ServiceMonitor (in the `ingress` namespace) to
    # be picked up automatically in Step 5.
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false

    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi

    # Static scrape for cloudflared on lab-edge01 (out-of-cluster).
    # Step 6 fills this with a real config; for the initial install
    # we deploy with an empty list and add the entry as a follow-up
    # so install failures and scrape failures are independent.
    additionalScrapeConfigs: []

    # Resource caps — generous floor, hard ceiling.
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
      limits:
        cpu: 2000m
        memory: 4Gi

# ---------------------------------------------------------------- grafana
grafana:
  enabled: true
  replicas: 1

  # Admin password is supplied via --set on the Helm command line in
  # Step 4.3, decrypted on the fly from the SOPS-sealed file. We do
  # NOT put the password in this values.yaml — values.yaml is committed.
  admin:
    existingSecret: ""                 # we use --set adminPassword instead
  # adminUser stays "admin" (chart default).

  persistence:
    enabled: true
    storageClassName: local-path
    accessModes: ["ReadWriteOnce"]
    size: 5Gi

  # Pin Grafana to the same node as Prometheus — keeps the local-path
  # PVs co-resident on lab-wk01, simplifies snapshot/restore.
  nodeSelector:
    kubernetes.io/hostname: lab-wk01

  service:
    type: ClusterIP                    # exposed via Ingress in Step 7, not LoadBalancer

  # Ingress is created OUT-OF-BAND (Step 7.2) so we can review the
  # Ingress YAML separately and not entangle it with chart values.
  ingress:
    enabled: false

  # Default datasource: in-cluster Prometheus.
  sidecar:
    datasources:
      enabled: true
      defaultDatasourceEnabled: true
    dashboards:
      enabled: true                    # auto-discover ConfigMap-mounted dashboards
      label: grafana_dashboard
      labelValue: "1"

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1000m
      memory: 1Gi

# ---------------------------------------------------------------- node-exporter
nodeExporter:
  enabled: true                        # DaemonSet across all 5 nodes

prometheus-node-exporter:
  hostRootFsMount:
    enabled: true
    mountPropagation: HostToContainer

# ---------------------------------------------------------------- ksm
kubeStateMetrics:
  enabled: true

# ---------------------------------------------------------------- defaults
# Disable the default scrape jobs we don't need / can't reach in k3s.
kubeApiServer:
  enabled: true
kubelet:
  enabled: true
kubeControllerManager:
  enabled: false                       # k3s combines into a single binary; not separately scrapable
kubeScheduler:
  enabled: false                       # same
kubeProxy:
  enabled: false                       # we run kube-proxy-replacement via Cilium (runbook 02 § 4.2)
kubeEtcd:
  enabled: false                       # k3s embedded etcd; metrics endpoint not exposed by default

# ---------------------------------------------------------------- crds
# kube-prometheus-stack ships its own CRDs (ServiceMonitor, etc.).
# `helm install` applies them only on first install; upgrades skip
# CRDs by design. If we ever upgrade the chart, the runbook should
# remind us to `kubectl apply` the CRDs from the chart's `crds/` dir
# manually first.
crds:
  enabled: true

# ---------------------------------------------------------------- pdb
defaultRules:
  create: true                         # ship the default rule set; we won't alert on it (no Alertmanager)
  rules:
    alertmanager: false                # don't bother with alertmanager rules
```

> **Why disable `kubeControllerManager`, `kubeScheduler`, `kubeProxy`,
> `kubeEtcd`?** k3s bundles the control-plane binaries into a single
> process, and embedded etcd's metrics endpoint isn't exposed by
> default. The chart's default ServiceMonitors for these would all
> fail to scrape, generating noisy `up == 0` alerts that aren't real
> failures. ARCH § 5.1 / § 5.2 already constrain this; the values.yaml
> just makes it explicit. If you ever expose etcd metrics (Phase 4
> consideration), flip `kubeEtcd.enabled` back on.
>
> **Why `serviceMonitorSelectorNilUsesHelmValues: false`?** kube-
> prometheus-stack defaults to selecting only ServiceMonitors with the
> chart's release label. Setting this to `false` makes Prometheus
> select *all* ServiceMonitors in any namespace, which is what we want
> so ingress-nginx's ServiceMonitor (in the `ingress` namespace) is
> picked up. The same applies to PodMonitors, PrometheusRules, and
> Probes. The trade-off is "any random ServiceMonitor anyone creates
> gets scraped" — for a single-operator lab, that's a feature.

### 4.3 Install

```sh
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --version 84.5.0 --values k8s/kube-prometheus-stack/values.yaml --set "grafana.adminPassword=$(sops --decrypt ansible/group_vars/monitoring/grafana.enc.yaml | yq -r .grafana_admin_password)"
```

> Single physical line per `MEMORY.md → feedback_paste_fragility.md`.
> Long, but it pastes cleanly. The `--set` decrypts the password on
> the fly — plaintext only exists in the pipe between sops and helm,
> never on disk, never in shell history (leading-space the line if
> your `HISTCONTROL` doesn't already strip helm calls).

Watch the rollout:

```sh
kubectl -n monitoring get pods -w
# Ctrl-C once these are all Running:
#   kube-prometheus-stack-operator              1/1 Running
#   prometheus-kube-prometheus-stack-prometheus-0  2/2 Running
#   alertmanager-* — should NOT exist (alertmanager.enabled=false)
#   kube-prometheus-stack-grafana-*             3/3 Running
#   kube-prometheus-stack-kube-state-metrics-*  1/1 Running
#   kube-prometheus-stack-prometheus-node-exporter-*  1/1 Running × 5 (one per node)
```

If a pod is `Pending` for more than 90 s, check:

```sh
kubectl -n monitoring describe pod <pod-name>
# Look at the Events: bottom — likely "0/5 nodes are available"
# with a reason. nodeSelector mismatches and PVC binding are the
# usual culprits.
```

### 4.4 Verify Prometheus is up and scraping

```sh
# Targets — should be Up for kubelet, kube-apiserver, kube-state-metrics,
# node-exporter, the operator itself, and Prometheus's own self-scrape.
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health}' | head -40
# Then kill the port-forward:
kill %1 2>/dev/null; sleep 1
```

Expect every job to be `"health":"up"`. The cloudflared static target
is **not** here yet — Step 6 adds it.

If anything is `"down"`, look at `lastError` in the same JSON. Common
causes at this stage:

- `kubelet` down → Cilium kube-proxy-replacement isn't routing
  ServiceMonitor probes correctly. Re-check `cilium status`.
- `kube-apiserver` down → ServiceMonitor authn/z; usually fixed by
  ensuring the chart's RBAC ServiceAccount got created (it's in the
  default install).

### Decision gate before Step 5

- [ ] All `kube-prometheus-stack` pods are `Running` and `Ready`.
- [ ] Prometheus's `/api/v1/targets` shows every default job `up`.
- [ ] No Alertmanager pods exist (verify
      `kubectl -n monitoring get pods | grep alertmanager` returns
      nothing).
- [ ] Grafana pod logs show no panic / restart loops:
      `kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana | tail`.

---

## Step 5 — Flip the ingress-nginx ServiceMonitor on

Runbook 02 § 6.1 left `serviceMonitor.enabled: false` pending this
runbook. Now it gets flipped on and Helm's upgrade-in-place picks up
the change.

### 5.1 Edit `k8s/ingress-nginx/values.yaml`

Find the `metrics:` block and flip the nested `serviceMonitor.enabled`:

```yaml
controller:
  # ... unchanged above ...
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true                        # was: false (flipped 2026-05-01, runbook 04 § 5)
      additionalLabels:
        release: kube-prometheus-stack     # belt-and-suspenders: explicit label even though serviceMonitorSelectorNilUsesHelmValues=false makes it optional
```

The `additionalLabels` line is intentional redundancy. Even though
Step 4's Prometheus values disable the release-label filter, leaving
the label in place keeps the ServiceMonitor compatible with a future
strict-mode Prometheus without another edit.

### 5.2 Helm upgrade ingress-nginx in place

```sh
helm upgrade ingress-nginx ingress-nginx/ingress-nginx --namespace ingress --version 4.11.8 --values k8s/ingress-nginx/values.yaml
```

> **Version-pin note** (from the 2026-05-01 first execution). Originally
> pinned 4.11.3 (matching runbook 02). At first execution the chart
> index had pruned 4.11.3 entirely; the available 4.11.x line was
> 4.11.4 through 4.11.8. Bumped to 4.11.8 (latest patch in the line).
> Patch bumps in 4.11.x are CVE/bug fixes only — values schema is
> stable across the line. Same staleness-check pattern as the
> kube-prometheus-stack bump in § 4.1: search the repo, pick the
> latest patch in the line we trust, document the bump.

This is an in-place value + version change. The values diff (adding
`serviceMonitor.enabled: true` + `additionalLabels`) does **not**
touch the controller Deployment template, but the chart-version bump
*does* roll the pods because the underlying nginx-ingress image
moves with each patch. Rolling restart is intentional — that's how we
pick up the patched binary. The 2-replica controller (runbook 02 §
6.1) means there's no service-level outage during the roll.

Confirm the VIP doesn't drift:

```sh
kubectl -n ingress get svc ingress-nginx-controller -o wide
# EXTERNAL-IP must still be 10.10.20.50.
```

If the VIP drifted, runbook 03's tunnel upstream is broken and you
need to fix the MetalLB `loadBalancerIPs` annotation immediately. (It
shouldn't drift — Step 5 doesn't touch the LB annotation — but verify
because it's load-bearing for runbook 03.)

### 5.3 Verify the new ServiceMonitor and target

```sh
kubectl -n ingress get servicemonitor
# Expect: ingress-nginx-controller (or similar — name may vary by chart minor)

# Re-port-forward Prometheus and look for the new target.
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | test("ingress")) | {job:.labels.job, health, scrapeUrl}'
kill %1 2>/dev/null; sleep 1
```

Expect at least one ingress-nginx target, `"health":"up"`, scrapeUrl
pointing at one of the controller pod IPs on port `10254` (the
chart's default metrics port).

### Decision gate before Step 6

- [ ] `k8s/ingress-nginx/values.yaml` has `serviceMonitor.enabled: true`.
- [ ] `helm upgrade` succeeded.
- [ ] `ingress-nginx-controller` Service still has EXTERNAL-IP
      `10.10.20.50`.
- [ ] Prometheus has at least one ingress-nginx target, all `up`.

---

## Step 6 — cloudflared static scrape (rebind + Prometheus config)

Two sub-changes that must happen in the right order:

1. Rebind cloudflared metrics from `127.0.0.1:2000` → `10.10.30.21:2000`
   (Step 6.1). After this, the endpoint is reachable from the cluster
   thanks to Step 1's firewall rule.
2. Add the static scrape entry to Prometheus values and `helm upgrade`
   (Step 6.2). Prometheus picks the entry up and starts scraping.

If you do (2) before (1), the scrape fails until (1) lands — not
catastrophic, but you'll be staring at a `down` target wondering why
when the answer is "you haven't rebound yet". Order matters.

### 6.1 — Rebind cloudflared's metrics endpoint

Edit `cloudflared/config.yaml.tmpl` in the repo. Find the `metrics:`
line and change it:

```yaml
# Before:
metrics: 127.0.0.1:2000        # Prometheus scrape target (runbook 04)

# After:
metrics: 10.10.30.21:2000      # Prometheus scrape target (runbook 04 § 6.1). Bound to the dmz interface specifically (not 0.0.0.0). Reachable from cluster VLAN per ADR-0015.
```

Re-materialize onto `lab-edge01` (same pattern as runbook 03 § 5.2 —
single physical line):

```sh
sed "s/<TUNNEL_UUID>/$(cat ~/.scratch/tunnel-uuid)/" cloudflared/config.yaml.tmpl | ssh ubuntu@10.10.30.21 'sudo tee /etc/cloudflared/config.yaml >/dev/null && sudo chown cloudflared:cloudflared /etc/cloudflared/config.yaml && sudo chmod 0644 /etc/cloudflared/config.yaml'
```

Validate config syntax before restarting:

```sh
ssh ubuntu@10.10.30.21 'sudo -u cloudflared cloudflared --config /etc/cloudflared/config.yaml ingress validate'
# Expect: OK
```

Restart cloudflared:

```sh
ssh ubuntu@10.10.30.21 'sudo systemctl restart cloudflared && sleep 3 && sudo systemctl is-active cloudflared'
# Expect: active
```

Tail the journal for ~30s to confirm tunnel re-registers (4 connections
to two colos, same as runbook 03 § 6.2):

```sh
ssh ubuntu@10.10.30.21 'sudo journalctl -fu cloudflared'   # Ctrl-C after observing 4× "Connection ... registered"
```

Confirm metrics are reachable on the new bind from the dmz host
itself (still loopback-equivalent — proves the rebind):

```sh
ssh ubuntu@10.10.30.21 'curl -sI --max-time 3 http://10.10.30.21:2000/metrics | head -1'
# Expect: HTTP/1.1 200 OK
```

And from a cluster pod (proves the firewall + rebind together):

```sh
kubectl run cf-probe --rm -it --restart=Never --image=nicolaka/netshoot -- bash -lc 'curl -sI --max-time 3 http://10.10.30.21:2000/metrics | head -1; echo exit=$?'
# Expect: HTTP/1.1 200 OK; exit=0
```

If the cluster probe fails after the dmz-local probe succeeds, you've
got a firewall problem (Step 1's rule didn't apply or got reordered).

### 6.2 — Add the static scrape entry to Prometheus values

Edit `k8s/kube-prometheus-stack/values.yaml`. Find:

```yaml
    additionalScrapeConfigs: []
```

Replace with:

```yaml
    additionalScrapeConfigs:
      - job_name: cloudflared-edge01
        scrape_interval: 30s
        scrape_timeout: 10s
        metrics_path: /metrics
        static_configs:
          - targets: ['10.10.30.21:2000']
            labels:
              service: cloudflared
              tunnel: cucox-lab-prod
              host: lab-edge01
              vlan: dmz
```

> **Why labels?** Lets the Grafana dashboards filter on `service`,
> `tunnel`, `host`, and `vlan` without inferring them from the raw
> instance string. When a future second cloudflared (Phase 5
> in-cluster) scrapes alongside this one, the same dashboard panels
> still work because they filter on `service: cloudflared`, not on
> `instance: 10.10.30.21:2000`.

Apply via Helm upgrade:

```sh
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --namespace monitoring --version 84.5.0 --values k8s/kube-prometheus-stack/values.yaml --reuse-values --set "grafana.adminPassword=$(sops --decrypt ansible/group_vars/monitoring/grafana.enc.yaml | yq -r .grafana_admin_password)"
```

`--reuse-values` keeps every other value the same; only the
`additionalScrapeConfigs` change reaches Prometheus. The Prometheus
operator reconciles this without restarting Prometheus (the
configmap-based reload is hot).

### 6.3 — Verify the new target

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="cloudflared-edge01") | {job:.labels.job, health, scrapeUrl, lastError}'
kill %1 2>/dev/null; sleep 1
```

Expect:

```json
{
  "job": "cloudflared-edge01",
  "health": "up",
  "scrapeUrl": "http://10.10.30.21:2000/metrics",
  "lastError": ""
}
```

If `health == "down"` with `lastError` mentioning timeout, suspect
firewall (Step 1.2 rule order). If `lastError` mentions connection
refused, cloudflared bind is wrong (re-do Step 6.1).

### Decision gate before Step 7

- [ ] cloudflared metrics endpoint bound to `10.10.30.21:2000`,
      reachable both from the dmz host and from a cluster pod.
- [ ] Tunnel still HEALTHY in the Cloudflare dashboard with 4 active
      connections (the rebind shouldn't have affected this — verify).
- [ ] Prometheus has the `cloudflared-edge01` target, `up`.
- [ ] `journalctl -u cloudflared` is clean over a **continuous 5-minute
      observation window** after the rebind. No `ERR` lines, no
      reconnect loops. Do not skip the window.

---

## Step 7 — Grafana ingress + internal DNS + first login

Grafana is running with `service.type: ClusterIP` and no Ingress yet.
This step makes it reachable from the Mac Air at
`https://grafana.lab.cucox.local/`.

### 7.1 — Internal DNS on the Mac Air

Add a single line to `/etc/hosts`:

```sh
sudo sh -c 'printf "10.10.20.50\tgrafana.lab.cucox.local\n" >> /etc/hosts'
grep grafana.lab.cucox.local /etc/hosts
# Expect: 10.10.20.50    grafana.lab.cucox.local
```

> **Why /etc/hosts and not the UCG-Max DNS forwarder?**
> `/etc/hosts` is operator-only: only the Mac Air resolves it. If we
> later want every CucoxLab-Mgmt SSID client to resolve
> `*.lab.cucox.local`, we add a UCG-Max DNS forwarder rule (or a small
> CoreDNS instance per ARCH § 5.5) — that's a Phase 4 follow-up. For
> Phase 2 we keep the surface area minimal: the only resolver that
> knows the name is the operator's laptop.
>
> The /etc/hosts approach also means a misconfigured ingress can never
> accidentally take traffic from any other client on the segment —
> failing closed.

### 7.2 — Create the Ingress resource

Create `k8s/kube-prometheus-stack/grafana-ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    # No TLS yet — cert-manager + Let's Encrypt is a Phase 3 follow-up
    # (see ARCH § 5.4 footnote candidate). Until then we serve over
    # HTTP on the internal hostname; the request never leaves the lab
    # VLANs.
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: grafana.lab.cucox.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
```

> **Why no TLS?** The hostname is internal-only. Adding a self-signed
> cert here would just train the operator to click through TLS warnings
> — exactly the wrong habit. cert-manager (Phase 3) will issue a real
> cert for the internal hostname via the DNS-01 challenge against the
> Cloudflare zone, at which point we flip `ssl-redirect` back on. For
> Phase 2, the request path is mac-air → mgmt VLAN → ingress VIP on
> cluster VLAN. No external network involved.

Apply:

```sh
kubectl apply -f k8s/kube-prometheus-stack/grafana-ingress.yaml
kubectl -n monitoring get ingress grafana
# Expect: ADDRESS = 10.10.20.50, HOSTS = grafana.lab.cucox.local
```

The `ADDRESS` may take 30–60s to populate. If it stays empty, check
`kubectl -n ingress logs deploy/ingress-nginx-controller | tail -50`
for parser errors.

### 7.3 — First login

```sh
open http://grafana.lab.cucox.local/
# OR, in the terminal: curl -sI http://grafana.lab.cucox.local/
# Expect: HTTP/1.1 302 Found, Location: /login
```

In the browser, log in:

- Username: `admin`
- Password: read it from sops on the fly (do NOT paste from history):

  ```sh
  sops --decrypt ansible/group_vars/monitoring/grafana.enc.yaml | yq -r .grafana_admin_password
  ```

  Copy from the terminal, paste into Grafana's login. Verify dashboard
  index loads. Look for the Prometheus datasource in
  **Connections → Data sources** — it should already be configured by
  the chart's sidecar (auto-discovered).

### Decision gate before Step 8

- [ ] `grafana.lab.cucox.local` resolves to `10.10.20.50` on the
      Mac Air (`dscacheutil -q host -a name grafana.lab.cucox.local`
      returns it).
- [ ] `kubectl -n monitoring get ingress grafana` shows ADDRESS
      `10.10.20.50`.
- [ ] `http://grafana.lab.cucox.local/` returns 302 to `/login`.
- [ ] Login succeeds with the SOPS-decrypted password.
- [ ] Prometheus datasource is present and healthy in
      **Connections → Data sources → Prometheus → Test** (returns
      "Data source is working").

---

## Step 8 — Seed three landing dashboards

ARCH § 7.1 calls out three dashboards: cluster overview, k8s control-
plane, workload per-namespace. kube-prometheus-stack ships ~30
dashboards by default — including very good versions of all three —
but they're scattered through the dashboard list and don't have the
Cucox Lab labels (`service: cloudflared`, the `tunnel` label, etc.).

We seed three curated landing dashboards as ConfigMaps with the chart-
recognized label `grafana_dashboard: "1"`. The Grafana sidecar picks
them up automatically and adds them to a "Cucox Lab" folder.

### 8.1 — Folder

Grafana doesn't get a "create folder" CR; folders are created on the
fly by the sidecar based on a `grafana_folder` label. Set
`grafana_folder: "Cucox Lab"` on each ConfigMap.

### 8.2 — Dashboard 1: Cluster overview

This one is mostly the chart-bundled "Kubernetes / Compute Resources /
Cluster" dashboard, lifted into our folder. We don't re-author it.

Create `k8s/kube-prometheus-stack/dashboards/01-cluster-overview.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cucox-lab-cluster-overview
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Cucox Lab"
data:
  cucox-lab-cluster-overview.json: |-
    {
      "title": "Cucox Lab — Cluster overview",
      "uid": "cucox-cluster-overview",
      "tags": ["cucox-lab", "phase-2"],
      "timezone": "browser",
      "schemaVersion": 39,
      "panels": [
        {"type":"stat","title":"Nodes Ready","targets":[{"expr":"sum(kube_node_status_condition{condition=\"Ready\",status=\"true\"})"}]},
        {"type":"timeseries","title":"CPU usage by node","targets":[{"expr":"sum by (node) (rate(node_cpu_seconds_total{mode!=\"idle\"}[5m]))"}]},
        {"type":"timeseries","title":"Memory used by node","targets":[{"expr":"sum by (instance) (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)"}]},
        {"type":"timeseries","title":"Disk used by node (rootfs)","targets":[{"expr":"sum by (instance) (node_filesystem_size_bytes{mountpoint=\"/\"} - node_filesystem_avail_bytes{mountpoint=\"/\"})"}]},
        {"type":"timeseries","title":"Net rx/tx by node","targets":[{"expr":"sum by (instance) (rate(node_network_receive_bytes_total[5m]))","legendFormat":"rx {{instance}}"},{"expr":"sum by (instance) (rate(node_network_transmit_bytes_total[5m]))","legendFormat":"tx {{instance}}"}]}
      ]
    }
```

> **Why hand-rolled JSON in a ConfigMap rather than using a Grafana
> import dashboard ID?** Three reasons: (1) the chart-bundled
> dashboards already cover the "import-by-ID" case; (2) seeding a
> hand-rolled dashboard in the repo is reviewable in PR — a UI-imported
> dashboard isn't; (3) panel positions in this skeleton are
> auto-laid-out by Grafana when JSON omits `gridPos`. We'll add explicit
> `gridPos` after first render once we know which panels we want big.

Apply once you've placed all three files (next two sub-steps):

### 8.3 — Dashboard 2: k8s control-plane

`k8s/kube-prometheus-stack/dashboards/02-k8s-control-plane.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cucox-lab-k8s-control-plane
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Cucox Lab"
data:
  cucox-lab-k8s-control-plane.json: |-
    {
      "title": "Cucox Lab — k8s control plane",
      "uid": "cucox-k8s-cp",
      "tags": ["cucox-lab", "phase-2", "control-plane"],
      "timezone": "browser",
      "schemaVersion": 39,
      "panels": [
        {"type":"stat","title":"API server up","targets":[{"expr":"up{job=\"apiserver\"}"}]},
        {"type":"timeseries","title":"API request rate","targets":[{"expr":"sum by (verb) (rate(apiserver_request_total[5m]))"}]},
        {"type":"timeseries","title":"API request duration p99","targets":[{"expr":"histogram_quantile(0.99, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket[5m])))"}]},
        {"type":"timeseries","title":"API 5xx error rate","targets":[{"expr":"sum by (verb) (rate(apiserver_request_total{code=~\"5..\"}[5m]))"}]}
      ]
    }
```

> Etcd metrics are intentionally absent — k3s embedded etcd doesn't
> expose its metrics endpoint by default, and `values.yaml` disables
> the `kubeEtcd` ServiceMonitor for that reason. When Phase 4 wires
> etcd metrics, add an "Etcd latency" panel here.

### 8.4 — Dashboard 3: workload per-namespace

`k8s/kube-prometheus-stack/dashboards/03-workload-per-namespace.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cucox-lab-workload-per-namespace
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    grafana_folder: "Cucox Lab"
data:
  cucox-lab-workload-per-namespace.json: |-
    {
      "title": "Cucox Lab — Workload per namespace",
      "uid": "cucox-workload-ns",
      "tags": ["cucox-lab", "phase-2", "workloads"],
      "timezone": "browser",
      "schemaVersion": 39,
      "templating": {
        "list": [
          {
            "name": "namespace",
            "type": "query",
            "datasource": {"type":"prometheus","uid":"prometheus"},
            "query": "label_values(kube_pod_info, namespace)",
            "current": {"text":"All","value":"$__all"},
            "includeAll": true
          }
        ]
      },
      "panels": [
        {"type":"stat","title":"Pods running","targets":[{"expr":"sum(kube_pod_status_phase{namespace=~\"$namespace\",phase=\"Running\"})"}]},
        {"type":"timeseries","title":"CPU per workload","targets":[{"expr":"sum by (workload) (label_replace(rate(container_cpu_usage_seconds_total{namespace=~\"$namespace\"}[5m]), \"workload\", \"$1\", \"pod\", \"(.*)-[^-]+-[^-]+\"))"}]},
        {"type":"timeseries","title":"Memory per workload","targets":[{"expr":"sum by (workload) (label_replace(container_memory_working_set_bytes{namespace=~\"$namespace\"}, \"workload\", \"$1\", \"pod\", \"(.*)-[^-]+-[^-]+\"))"}]},
        {"type":"timeseries","title":"Pod restarts (last 24h)","targets":[{"expr":"sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total{namespace=~\"$namespace\"}[24h]))"}]}
      ]
    }
```

The `workload` derivation via `label_replace` is approximate (it strips
the trailing replicaset+pod suffix); replace with a proper join against
`kube_pod_owner` once the dashboards are getting real use.

### 8.5 — Apply

```sh
kubectl apply -f k8s/kube-prometheus-stack/dashboards/
# Expect: 3 configmap/* created (or unchanged on re-apply).
```

Wait ~30s for the Grafana sidecar to pick them up, then refresh
Grafana in the browser. **Dashboards → Browse → Cucox Lab** folder
should show the three.

> **If the folder doesn't appear,** the `grafana_folder` annotation
> dispatch is sidecar-version-dependent. Two fallbacks: (a) bump
> kube-prometheus-stack chart minor and re-test; (b) drop the
> `grafana_folder` annotation, the dashboards land in **General** —
> tag them `cucox-lab` and bookmark.

### Decision gate before Step 9

- [ ] All three ConfigMaps exist:
      `kubectl -n monitoring get cm -l grafana_dashboard=1 | grep cucox-lab`.
- [ ] All three dashboards visible in Grafana under **Dashboards →
      Browse → Cucox Lab** (or under **General** if the folder
      annotation didn't take).
- [ ] Each dashboard renders panels with **no datasource errors** —
      `Test` each datasource if errors appear.
- [ ] The cluster-overview dashboard "Nodes Ready" panel shows 5.

---

## Step 9 — Snapshot, document, file edits

### 9.1 Per-VM snapshot

Worker `lab-wk01` is the only one with new persistent state on disk
(local-path PVs for Prometheus + Grafana). Snapshot it specifically:

```sh
ssh root@10.10.10.10 'qm snapshot 131 phase2-observability --description "post kube-prometheus-stack install + dashboards"'
# 131 is lab-wk01's vmid; adjust if your terraform inventory chose a different ID.
```

For uniform rollback semantics, snapshot all six VMs that this runbook
touched — the five cluster VMs **plus** `lab-edge01` (vmid 141). The
four cluster nodes other than `lab-wk01` only carry chart manifests
(no PV data), but a uniform snapshot generation simplifies future
"rollback to phase2-observability" plays. `lab-edge01` is included
because runbook 04 § 6.1 rebound cloudflared's metrics endpoint —
the runbook 03 snapshot ("phase2-cloudflared") on this VM is now
stale relative to the live config, and a fresh `phase2-observability`
snapshot captures the rebind state.

```sh
ssh root@10.10.10.10 'for v in 121 122 123 131 132 141; do qm snapshot "$v" "phase2-observability" --description "post kube-prometheus-stack install + dashboards + cloudflared metrics rebind"; done'
```

### 9.2 Update ARCHITECTURE.md

Two edits:

**§ 3.3.1** — add a row to the inter-VLAN matrix:

```
| cluster | dmz | tcp/443 to ingress, tcp/7844 to cloudflared, tcp/2000 to cloudflared metrics on lab-edge01 | Specific service ports only. The :2000 entry is per ADR-0015 (Phase 2 observability). |
```

(Replace the existing `cluster | dmz | tcp/443 to ingress, tcp/7844 to cloudflared` row.)

**§ 12 decision log** — append:

```
| 0015 | 2026-05-01 | Open `cluster (10.10.20.0/24) → dmz (10.10.30.21):tcp/2000` so in-cluster Prometheus can scrape the cloudflared metrics endpoint on lab-edge01. Time-boxed: closes when Phase 5 moves cloudflared in-cluster. cloudflared metrics rebind from `127.0.0.1:2000` to `10.10.30.21:2000` is the consequential config change. See [ADR-0015](./docs/decisions/0015-cluster-dmz-2000-prometheus-cloudflared.md). | Active (deviation, time-boxed) |
```

**§ 7.1** — replace the (currently aspirational) wording with what
actually shipped, and link this runbook:

```
The Phase 2 observability stack landed via runbook 04. Prometheus 1
replica with 30d retention on `local-path` pinned to `lab-wk01`.
Grafana 1 replica behind ingress at the internal hostname
`grafana.lab.cucox.local` (resolved on the operator workstation via
`/etc/hosts`). `node_exporter` DaemonSet across all 5 nodes.
`kube-state-metrics` with default ServiceMonitors. ingress-nginx
ServiceMonitor enabled. cloudflared (out-of-cluster on `lab-edge01`)
scraped via `additionalScrapeConfigs` static target `10.10.30.21:2000`.
Three seeded "Cucox Lab" landing dashboards: cluster overview, k8s
control plane, workload per namespace. Alertmanager is deferred to
Phase 4 per § 7.2.
```

### 9.3 Files to commit on a `phase2-observability` branch

(Claude Code handles `git`; this runbook lists the file set so the
commit is reviewable.)

**New files:**

| Path | Purpose |
|---|---|
| `k8s/kube-prometheus-stack/values.yaml` | Helm chart values (Prometheus, Grafana, scrapers, additionalScrapeConfigs) |
| `k8s/kube-prometheus-stack/grafana-ingress.yaml` | Internal Ingress for Grafana on `grafana.lab.cucox.local` |
| `k8s/kube-prometheus-stack/dashboards/01-cluster-overview.yaml` | Seed dashboard ConfigMap |
| `k8s/kube-prometheus-stack/dashboards/02-k8s-control-plane.yaml` | Seed dashboard ConfigMap |
| `k8s/kube-prometheus-stack/dashboards/03-workload-per-namespace.yaml` | Seed dashboard ConfigMap |
| `ansible/group_vars/monitoring/grafana.enc.yaml` | SOPS-encrypted Grafana admin password |
| `docs/runbooks/04-phase2-observability.md` | This file |
| `docs/decisions/0015-cluster-dmz-2000-prometheus-cloudflared.md` | ADR for the new firewall allow + cloudflared metrics rebind |

**Edited files:**

| Path | Change |
|---|---|
| `k8s/ingress-nginx/values.yaml` | `controller.metrics.serviceMonitor.enabled: true` (was `false`); `additionalLabels.release: kube-prometheus-stack` added |
| `cloudflared/config.yaml.tmpl` | `metrics:` rebound `127.0.0.1:2000` → `10.10.30.21:2000` |
| `ARCHITECTURE.md` | § 3.3.1 row updated, § 7.1 prose refreshed, § 12 row 0015 added |

**Ignored (must NOT be committed):**

| Path | Why |
|---|---|
| `~/.kube/cucox-lab.yaml` | Operator kubeconfig — already gitignored |
| Any plaintext copy of the Grafana admin password | Should not exist; if a temporary file slipped into the repo, `chmod 600 && rm -P` it (memory: `feedback_macos_rm_secure_delete.md`) |
| `/etc/hosts` line on the Mac Air | Outside the repo by design |

---

## Rollback

The right rollback depends on what failed and when.

### Prometheus / Grafana refuses to schedule (Step 4)

- Symptoms: pods Pending, `kubectl describe` cites `nodeSelector` or
  `Insufficient ephemeral-storage`.
- Action: edit `k8s/kube-prometheus-stack/values.yaml` —
  reduce `prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage`
  (50Gi → 30Gi or so) and `retentionSize` proportionally; or change
  the `nodeSelector` to a worker with more headroom.
  Re-run `helm upgrade` per Step 4.3.
- Don't `kubectl delete pvc` to "fix" a stuck PVC — that orphans
  retained PVs on the node. Use `helm uninstall` first if you really
  need to start over.

### ingress-nginx restarts after Step 5 and the VIP drifts

- Symptoms: `ingress-nginx-controller` Service `EXTERNAL-IP` is no
  longer `10.10.20.50`. cloudflared tunnel goes UNHEALTHY shortly
  after.
- Action: re-check the `metallb.universe.tf/loadBalancerIPs`
  annotation in `k8s/ingress-nginx/values.yaml` — it should still be
  `10.10.20.50`. Re-run `helm upgrade ingress-nginx ...`.
- This shouldn't happen — Step 5's diff doesn't touch the LB
  annotation — but it's load-bearing so pre-flight the rollback path
  before doing the upgrade.

### cloudflared keeps reconnecting after metrics rebind (Step 6.1)

- Symptoms: `journalctl -u cloudflared` shows repeated `WRN
  Connection terminated` lines after the rebind, tunnel stuck in
  registering loop.
- Action: revert `cloudflared/config.yaml.tmpl`'s `metrics:` line to
  `127.0.0.1:2000`, re-materialize, restart cloudflared. Then check
  whether it's the rebind that's at fault (highly unusual — `metrics:`
  is independent of the tunnel session) or whether the actual issue
  is dmz → External 7844 again (memory: `unifi_zone_firewall_gotchas.md`).

### Prometheus targets all `down` after Step 6.2

- Symptoms: every target shows `up == 0` post-upgrade. Grafana panels
  go gappy.
- Action: `kubectl -n monitoring describe pod prometheus-...-0` for
  the actual Prometheus container's events. Common cause: the
  `additionalScrapeConfigs` YAML had a typo and Prometheus's config
  reload failed; the chart accepts it but Prometheus rejects it on
  reload, and the operator falls back to the previous config — so the
  symptom is delayed and confusing.
- `kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 -c prometheus | tail -100`
  is the actual ground truth. Look for `error parsing config`.

### Full revert of this runbook

Component-level: `helm uninstall kube-prometheus-stack -n monitoring;
kubectl delete namespace monitoring`. Then revert
`k8s/ingress-nginx/values.yaml` and re-`helm upgrade` ingress-nginx,
revert `cloudflared/config.yaml.tmpl` and re-materialize. Remove the
firewall allow in UCG-Max.

VM-level: `qm rollback 131 phase2-observability` (this runbook's
snapshot — undoes the local-path PV state). The other four nodes
don't need rollback; they only carry chart manifests, not PV data.

---

## Done when

- [ ] `helm list -n monitoring` shows `kube-prometheus-stack` deployed
      at version `84.5.0`.
- [ ] `kubectl -n monitoring get pods` — every pod `Running` and
      `Ready`. Specifically: 1 prometheus, 1 grafana, 1 operator,
      1 kube-state-metrics, 5 node-exporter (one per node), **0
      alertmanager**.
- [ ] Prometheus `/api/v1/targets` shows every job `up`, including
      `cloudflared-edge01` with the new label set
      (`service: cloudflared`, `tunnel: cucox-lab-prod`,
      `host: lab-edge01`, `vlan: dmz`).
- [ ] ingress-nginx ServiceMonitor exists in the `ingress` namespace
      and is scraped by Prometheus (`up` for the `ingress-nginx`
      job).
- [ ] cloudflared metrics endpoint bound to `10.10.30.21:2000`,
      reachable from a cluster pod.
- [ ] cloudflared tunnel still **HEALTHY** in the Cloudflare dashboard
      with 4 active connections after the rebind (re-verify after a
      5-minute observation window).
- [ ] `journalctl -u cloudflared` clean over a continuous 5-minute
      window post-rebind.
- [ ] `grafana.lab.cucox.local` resolves to `10.10.20.50` on the
      Mac Air, login with the SOPS-decrypted password succeeds.
- [ ] All three "Cucox Lab" dashboards render with no datasource
      errors.
- [ ] `lab-wk01` has a `phase2-observability` snapshot.
- [ ] ADR-0015 stub exists; ARCH § 12 has the corresponding row;
      ARCH § 3.3.1 row reflects `tcp/2000`; ARCH § 7.1 prose has been
      refreshed.
- [ ] No public hostname maps to Grafana. Verify:

      ```sh
      dig +short grafana.cucox.me           # NXDOMAIN or no answer expected
      dig +short grafana.lab.cucox.local @1.1.1.1   # NXDOMAIN expected (only resolvable via /etc/hosts on the Mac Air)
      ```

      Both must return nothing. If either resolves, stop — the
      Cloudflare Access bootstrap is a prerequisite for any public
      hostname for an admin UI.

---

## Quick reference

### Where things live

| Thing | Location |
|---|---|
| Helm release | `kube-prometheus-stack` in namespace `monitoring` |
| Chart values | `k8s/kube-prometheus-stack/values.yaml` |
| Grafana ingress | `k8s/kube-prometheus-stack/grafana-ingress.yaml` |
| Seed dashboards | `k8s/kube-prometheus-stack/dashboards/` (3 ConfigMaps) |
| Grafana admin pw (sealed) | `ansible/group_vars/monitoring/grafana.enc.yaml` |
| Grafana URL (internal) | `http://grafana.lab.cucox.local/` (Mac Air `/etc/hosts` → 10.10.20.50) |
| Prometheus PV | `local-path` PV pinned to `lab-wk01` (50Gi) |
| Grafana PV | `local-path` PV pinned to `lab-wk01` (5Gi) |
| cloudflared metrics endpoint | `http://10.10.30.21:2000/metrics` (was `127.0.0.1:2000` — rebound 2026-05-01) |
| Static scrape config | `prometheus.prometheusSpec.additionalScrapeConfigs` in chart values |
| Firewall rule | UCG-Max `Lab-Cluster → Lab-DMZ` cell, allow `10.10.20.0/24 → 10.10.30.21:tcp/2000` |

### Diagnostic one-liners

```sh
# Pod health at a glance.
kubectl -n monitoring get pods

# All scrape targets and their health (port-forward Prometheus first).
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 2; curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health, lastError}'; kill %1

# Cloudflared metrics from a cluster pod.
kubectl run cf-probe --rm -it --restart=Never --image=nicolaka/netshoot -- curl -sI --max-time 3 http://10.10.30.21:2000/metrics | head -1

# Grafana log tail.
kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana --tail=100

# Grafana admin password (always pipe — never assign to a shell var).
sops --decrypt ansible/group_vars/monitoring/grafana.enc.yaml | yq -r .grafana_admin_password

# Confirm cloudflared still HEALTHY after rebind.
ssh ubuntu@10.10.30.21 'sudo systemctl is-active cloudflared; sudo journalctl -u cloudflared -n 30 --no-pager'
```

### Rollback ladder

1. **Config-level revert.** Re-apply previous chart values via
   `helm rollback kube-prometheus-stack <prev-revision> -n monitoring`.
2. **Component uninstall.** `helm uninstall kube-prometheus-stack -n
   monitoring; kubectl delete namespace monitoring`.
3. **Firewall revert.** Remove the new `cluster → dmz:2000` allow on
   UCG-Max; revert `cloudflared/config.yaml.tmpl` to
   `metrics: 127.0.0.1:2000` and re-materialize.
4. **VM revert.** `qm rollback 131 phase2-observability` — undoes
   PV state on `lab-wk01`.
5. **VM revert deeper.** `qm rollback 131 phase1-k3s` — runbook 02's
   snapshot. Redo this entire runbook from Step 2.

---

## Hand-off

Next: [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
— migrate `cucox.me` from GoDaddy to Cloudflare and complete the first
public cutover. Runbook 04 lights up the dashboards that runbook 05's
validation steps read; Runbook 05's `cucox.me` cutover is the first
public traffic that this stack observes.

**Phase 3 follow-ups that this runbook explicitly defers:**

- **Cloudflare Access bootstrap.** Zero Trust org → IdP (email or
  Google) → default-deny policy → app definition for any admin UI we
  expose. Lands when the first public hostname for an admin UI is
  proposed (likely `grafana.cucox.me`, after runbook 05's `cucox.me`
  pilot succeeds).
- **cert-manager + Let's Encrypt.** Once Access is in front of
  `grafana.*`, terminate TLS on a real cert via the DNS-01 challenge
  against Cloudflare. Flip `nginx.ingress.kubernetes.io/ssl-redirect`
  back to `"true"` on the Grafana Ingress.
- **Internal DNS at the gateway.** Replace `/etc/hosts` on the Mac
  Air with a UCG-Max DNS forwarder rule (or a small in-cluster CoreDNS
  zone) so any client on `CucoxLab-Mgmt` resolves `*.lab.cucox.local`
  without operator-side configuration. Per ARCH § 5.5.
- **Alertmanager + first alerts.** Per ARCH § 7.2, deferred until
  there's something worth being woken for.
