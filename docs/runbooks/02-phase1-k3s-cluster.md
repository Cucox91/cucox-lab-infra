# Runbook 02 — Phase 1: k3s HA Cluster, Cilium, MetalLB, ingress-nginx

> **Goal:** End the runbook with a 5-node k3s HA cluster running on the
> Phase 1 VMs (3 control-plane + 2 workers), Cilium as the CNI replacing
> Flannel, MetalLB serving the `10.10.20.50–.99` VIP pool, and
> ingress-nginx fronted by a MetalLB VIP. `kubectl` works from the Mac
> Air. A hello-world workload is reachable inside the cluster.
>
> The edge VM (`lab-edge01`) is *not* configured here — it joins the story
> in runbook 03 (Cloudflare Tunnel). For now it's a parked Ubuntu VM.
>
> **Estimated time:** 2 hours, of which Cilium and MetalLB are most of
> the troubleshooting risk.
>
> **Operator:** Raziel, Mac Air on `CucoxLab-Mgmt` (VLAN 10).

---

## What this runbook implements

| ARCHITECTURE.md ref | Implemented here |
|---|---|
| § 5.1 — Topology | `lab-cp01..03` form an embedded-etcd HA control plane; `lab-wk01..02` join as agents. |
| § 5.2 — CNI Cilium | k3s started with `--flannel-backend=none --disable-network-policy`. Cilium installed via Helm with kube-proxy replacement. |
| § 5.3 — Storage | `local-path-provisioner` (k3s built-in) confirmed as the default StorageClass. |
| § 5.4 — Ingress / LB | MetalLB L2 with the `.50–.99` pool. ingress-nginx with a `LoadBalancer` Service that pulls a MetalLB VIP. |
| § 9 — Secrets | The k3s join token is generated on `lab-cp01` and SOPS-encrypted into `ansible/group_vars/k3s/secrets.enc.yaml`. |
| ADR-0002 | This is where ADR-0002 (CNI: Cilium) actually pays out. |

What this runbook does **not** do: Cloudflare Tunnel (runbook 03),
Prometheus / Grafana (runbook 04), or any application workload (Phase 3).

---

## Prerequisites

- Runbook 01 complete. `terraform apply` clean. All six VMs reachable via
  `ssh ubuntu@<ip>` from the Mac Air on `CucoxLab-Mgmt`.
- Mac Air has `kubectl`, `helm`, `cilium` CLI installed:

  ```sh
  brew install kubectl helm cilium-cli
  kubectl version --client
  helm version
  cilium version --client
  ```

- The Mac Air's age private key is present at
  `~/.config/sops/age/keys.txt`. (You'll need this to encrypt the k3s
  join token.)

---

## Step 0 — Decide the cluster boundaries you'll re-derive later

Lock these values at the top of the runbook so the rest is mechanical.

| Variable | Value | Source |
|---|---|---|
| Pod CIDR | `10.42.0.0/16` | ARCH § 3.2 |
| Service CIDR | `10.43.0.0/16` | ARCH § 3.2 |
| MetalLB pool | `10.10.20.50-10.10.20.99` (50 addresses, plain range) | ARCH § 3.2, § 5.4 |
| K8s API VIP candidate | not used in Phase 1 — clients hit `10.10.20.21:6443` directly | ARCH § 5.1 |
| k3s version | `v1.30.x+k3s1` (stable channel as of 2026-04) | pinned per node |

> **Why no API VIP?** ARCHITECTURE.md § 5.1 bootstraps clients against
> `lab-cp01` directly. With three CP nodes and embedded etcd, this is
> fragile if `cp01` is the one that's down. We'll add a kube-VIP / HAProxy
> sidecar for the API in Phase 4 — call it out and move on.

---

## Step 1 — Generate the cluster join token

The token is the secret that lets new nodes join. We generate it now,
encrypt it, and reuse the same value for cp02/cp03 and the workers.

On the Mac Air. **Read this whole step before running anything** — token
plaintext must never touch the disk, the shell history, or `ps -ef`.

Discipline rules in force here (per ARCH §9 / ADR-0008):

- Prefix every command in this step with a leading space (your shell's
  `HISTCONTROL=ignorespace` or `ignoreboth` will skip history). Confirm:
  `echo $HISTCONTROL` should include `ignorespace`. If it doesn't,
  `export HISTCONTROL=ignoreboth` for this terminal.
- Never echo the token. Never put it in a heredoc that writes to a file.
- Pipe the token directly into `sops` so plaintext lives only in pipe
  buffers, never on disk.

```sh
 mkdir -p "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/ansible/group_vars/k3s"
 cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"

 # Generate a 64-char hex token and pipe it directly to sops, never to disk.
 # SOPS reads stdin for binary input and writes the encrypted YAML out.
 printf 'k3s_token: %s\n' "$(openssl rand -hex 32)" \
   | sops --encrypt --input-type yaml --output-type yaml /dev/stdin \
   > ansible/group_vars/k3s/secrets.enc.yaml

 # Verify it encrypted (file should contain `sops:` metadata block).
 head -3 ansible/group_vars/k3s/secrets.enc.yaml
```

To read the token at runtime, always pipe — never assign to a shell variable
that ends up in `ps -ef`:

```sh
 sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml | yq -r .k3s_token
```

When passing the token to a remote `ssh ... bash` (Steps 2 and 3), use stdin
piping with a quoted heredoc on the remote side. The token never appears in
the local shell's argv or env:

```sh
 sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml \
   | yq -r .k3s_token \
   | ssh ubuntu@10.10.20.21 'sudo K3S_TOKEN=$(cat) bash -s' << 'REMOTE'
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=... sh -s - server ...
REMOTE
```

The quoted `<<'REMOTE'` prevents local expansion of `$K3S_TOKEN`, and the
`$(cat)` on the remote side reads it from stdin inside the sudoed shell.
Steps 2 and 3 use this pattern.

---

## Step 2 — Bootstrap `lab-cp01` (the cluster initializer)

`lab-cp01` is the first control-plane node. It runs `k3s server
--cluster-init` which creates the embedded etcd cluster of size 1; cp02
and cp03 join as etcd peers.

### 2.1 Install on cp01

Token is piped via stdin into the remote sudoed shell — never in argv or
env on the local Mac Air. Note the **quoted** `<<'REMOTE'` heredoc, which
prevents local expansion of `$K3S_TOKEN`.

```sh
 sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml \
   | yq -r .k3s_token \
   | ssh ubuntu@10.10.20.21 'sudo K3S_TOKEN=$(cat) bash -s' << 'REMOTE'
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.30.5+k3s1" \
  sh -s - server \
    --cluster-init \
    --node-ip 10.10.20.21 \
    --advertise-address 10.10.20.21 \
    --tls-san 10.10.20.21 --tls-san 10.10.20.22 --tls-san 10.10.20.23 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=servicelb \
    --disable=traefik \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16 \
    --write-kubeconfig-mode 0644
REMOTE
```

**Why the four `--disable` flags?** ARCH §5.2 only spells out
`--flannel-backend=none --disable-network-policy`. We add `--disable=servicelb`
and `--disable=traefik` here because ARCH §5.4 mandates MetalLB (replacing
servicelb) and ingress-nginx (replacing traefik). The two extra disables
are the §5.2 + §5.4 commitments enforced at install time, not new
decisions.

Disabling-and-replacing checklist:

| Disabled | Why | Replaced by |
|---|---|---|
| flannel | We want eBPF, not VXLAN | Cilium (Step 4) |
| network-policy | Flannel's NP enforces nothing useful | Cilium NetworkPolicy + L7 |
| servicelb (klipper) | We want a real LB | MetalLB (Step 5) |
| traefik | We want nginx for parity with most ecosystems | ingress-nginx (Step 6) |

### 2.2 Verify cp01 alone

From cp01:

```sh
ssh ubuntu@10.10.20.21 'sudo k3s kubectl get nodes -o wide'
# Expected: cp01 NotReady (no CNI yet — that's normal until Step 4)
```

`NotReady` here is *expected*. Pods can't network until Cilium is in.
Don't be tempted to skip ahead and "fix it" by re-enabling Flannel.

---

## Step 3 — Join cp02, cp03, wk01, wk02

### 3.1 Helper functions

The token stays in a pipe; only the per-VM IP varies. Each call decrypts
once and pipes straight into ssh.

```sh
join_server () {
  local host_ip=$1
   sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml \
     | yq -r .k3s_token \
     | ssh ubuntu@"$host_ip" 'sudo K3S_TOKEN=$(cat) bash -s' << REMOTE
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.30.5+k3s1" \
  sh -s - server \
    --server https://10.10.20.21:6443 \
    --node-ip ${host_ip} \
    --advertise-address ${host_ip} \
    --tls-san 10.10.20.21 --tls-san 10.10.20.22 --tls-san 10.10.20.23 \
    --flannel-backend=none \
    --disable-network-policy \
    --disable=servicelb \
    --disable=traefik \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16
REMOTE
}

join_agent () {
  local host_ip=$1
   sops --decrypt ansible/group_vars/k3s/secrets.enc.yaml \
     | yq -r .k3s_token \
     | ssh ubuntu@"$host_ip" 'sudo K3S_TOKEN=$(cat) bash -s' << REMOTE
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.30.5+k3s1" \
  K3S_URL="https://10.10.20.21:6443" \
  sh -s - agent \
    --node-ip ${host_ip}
REMOTE
}

 join_server 10.10.20.22
 join_server 10.10.20.23
 join_agent  10.10.20.31
 join_agent  10.10.20.32
```

> **Heredoc subtlety:** the outer heredoc `<< REMOTE` (unquoted) lets the
> *local* shell expand `${host_ip}` only — the `$(cat)` is inside a
> single-quoted argument to `ssh`, so it's evaluated on the *remote* side
> against stdin (the piped token). This split is intentional.

### 3.2 Verify five-node cluster

```sh
scp ubuntu@10.10.20.21:/etc/rancher/k3s/k3s.yaml ~/.kube/cucox-lab.yaml

# macOS BSD sed (Mac Air): keep the empty '' after -i.
sed -i '' 's/127.0.0.1/10.10.20.21/' ~/.kube/cucox-lab.yaml
# GNU sed (Linux runner / CI): drop the empty arg → `sed -i 's/.../.../' ...`

chmod 600 ~/.kube/cucox-lab.yaml
export KUBECONFIG=~/.kube/cucox-lab.yaml

kubectl get nodes -o wide
```

Expected: 5 nodes, all `NotReady` (no CNI). If a node is missing, check
its journal: `ssh ubuntu@<ip> 'sudo journalctl -u k3s-agent -e'` for
agents, `k3s` for servers.

> **Add to your shell rc:** `export KUBECONFIG=~/.kube/cucox-lab.yaml`.
> The merge-into-`config` path is also fine, but a separate file makes it
> obvious which cluster you're hitting.

---

## Step 4 — Cilium

### 4.1 Add the chart

```sh
helm repo add cilium https://helm.cilium.io/
helm repo update
```

### 4.2 Values file

Create `k8s/cilium/values.yaml` in the repo:

```yaml
# k8s/cilium/values.yaml — see ADR-0002 for rationale.
ipam:
  mode: kubernetes
kubeProxyReplacement: true       # Cilium replaces kube-proxy entirely
k8sServiceHost: 10.10.20.21
k8sServicePort: 6443
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
operator:
  replicas: 2
routingMode: native              # native L3 (no VXLAN/Geneve overlay)
ipv4NativeRoutingCIDR: 10.42.0.0/16
autoDirectNodeRoutes: true
bpf:
  masquerade: true
loadBalancer:
  algorithm: maglev              # consistent hashing — useful for the broker work later
encryption:
  enabled: false                 # Phase 5 may flip this on
```

Native routing requires that nodes be on the same L2, which they are
(all cluster-VLAN VMs share `vmbr0.20`). If you ever spread nodes across
L3 boundaries, switch `routingMode` to `tunnel`.

> **Phase 5 watch-item:** when the Pi5 ARM workers join from the office
> switch (per ARCH § 2.2), they're still on the same `vmbr0.20`/cluster-VLAN
> over the trunk, so native routing continues to work. If that ever
> changes — e.g. routed cluster fabric — this is the first config to
> revisit. ARCH § 5.2 is silent on native vs tunnel; this runbook locks
> in native and ADR-0002 inherits the choice.

### 4.3 Install

```sh
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.16.3 \
  --values k8s/cilium/values.yaml

# Wait for it.
cilium status --wait
```

`cilium status` should land at:

```
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Hubble Relay:       OK
 \__/¯¯\__/    ClusterMesh:        disabled
    \__/

DaemonSet         cilium             Desired: 5, Ready: 5/5
Deployment        cilium-operator    Desired: 2, Ready: 2/2
```

### 4.4 Verify pod networking

```sh
kubectl get nodes
# All five nodes should now be Ready.

kubectl run debug --image=nicolaka/netshoot --rm -it --restart=Never -- bash
# Inside the pod:
#   curl -m 5 -k https://kubernetes.default.svc/healthz   # expect "ok" or 401
#   getent hosts kubernetes.default.svc
#   ping -c 2 10.42.0.1
```

If pods can't resolve `kubernetes.default.svc`, kube-proxy replacement
isn't fully active. Re-check that `--disable=traefik` and
`--flannel-backend=none` were on the *server* arg lists, not the agents
(common copy-paste error).

---

## Step 5 — MetalLB

### 5.1 Install

```sh
helm repo add metallb https://metallb.github.io/metallb
helm repo update

kubectl create namespace metallb-system
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --version 0.14.8
```

### 5.2 Configure the L2 pool

Create `k8s/metallb/pool.yaml`:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.10.20.50-10.10.20.99
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-pool-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lab-pool
```

Apply:

```sh
kubectl apply -f k8s/metallb/pool.yaml
```

### 5.3 Smoke-test a LoadBalancer Service

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: smoke-lb
  namespace: default
spec:
  type: LoadBalancer
  selector: { app: smoke }
  ports: [{ port: 80, targetPort: 8080 }]
EOF

kubectl get svc smoke-lb -w
# expect EXTERNAL-IP to land somewhere in 10.10.20.50-99 within ~5s
```

From the Mac Air (VLAN 10):

```sh
ping <the_external_ip>     # should reply via ARP from one of the cp/wk nodes
```

`ping` works because L2 ARP advertisement makes one of the cluster nodes
"own" the VIP at any given time. If ping fails, the most likely cause is
the upstream switch dropping unknown unicast — check the UCG-Max IGMP /
storm-control config.

Clean up:

```sh
kubectl delete svc smoke-lb
```

---

## Step 6 — ingress-nginx

### 6.1 Install

```sh
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

kubectl create namespace ingress
```

Create `k8s/ingress-nginx/values.yaml`:

```yaml
controller:
  replicaCount: 2
  service:
    type: LoadBalancer
    annotations:
      metallb.universe.tf/loadBalancerIPs: 10.10.20.50    # pin the VIP
  ingressClassResource:
    name: nginx
    default: true
  watchIngressWithoutClass: true
  config:
    use-forwarded-headers: "true"        # cloudflared sets X-Forwarded-*
    enable-real-ip: "true"
    proxy-body-size: "32m"
  metrics:
    enabled: true                         # for Phase 2 Prometheus
    serviceMonitor:
      enabled: false                      # turn on once kube-prometheus-stack lands
```

Pin the VIP to `.50` so the Cloudflare Tunnel runbook (03) has a stable
target.

### 6.2 Install

```sh
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress \
  --version 4.11.3 \
  --values k8s/ingress-nginx/values.yaml

kubectl -n ingress get svc ingress-nginx-controller
# EXTERNAL-IP should be 10.10.20.50.
```

### 6.3 End-to-end smoke test

```sh
kubectl create namespace smoke
kubectl -n smoke create deploy hello --image=nginxdemos/hello --port=80
kubectl -n smoke expose deploy hello --port=80
kubectl -n smoke create ingress hello \
  --class=nginx \
  --rule="hello.lab.cucox.local/*=hello:80"

# From the Mac Air (no real DNS yet, fake it):
curl -H 'Host: hello.lab.cucox.local' http://10.10.20.50/
# expect: NGINX demo HTML
```

If you get the Mac Air's NGINX (or any other 200), check the Host header.
If you get 502, the ingress controller can't reach the pod — check
`kubectl -n smoke get pods` and `kubectl -n ingress logs deploy/ingress-nginx-controller`.

Tear down the smoke namespace once happy:

```sh
kubectl delete namespace smoke
```

---

## Step 7 — Storage class sanity

`local-path-provisioner` should already be the default StorageClass —
k3s ships it.

```sh
kubectl get storageclass
# expect: local-path  (default)  ...
```

A quick PVC test confirms it:

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: pvc-test, namespace: default }
spec:
  accessModes: [ ReadWriteOnce ]
  resources: { requests: { storage: 1Gi } }
EOF

kubectl get pvc pvc-test -w   # should bind in seconds
kubectl delete pvc pvc-test
```

`local-path` PVs are tied to a specific node — fine for Phase 1. Longhorn
(replicated, node-failure-tolerant) is Phase 4 per ARCH § 5.3.

---

## Step 8 — Snapshot, then commit

### 8.1 Per-VM snapshot ("post k3s base")

A second snapshot layer on the Phase 1 VMs, after the cluster is healthy.
Lets you roll back tweaks without re-installing k3s.

```sh
ssh root@10.10.10.10 '
  for v in 121 122 123 131 132; do
    qm snapshot "$v" "phase1-k3s" --description "post k3s + Cilium + MetalLB + ingress"
  done
'
```

### 8.2 Commit + merge

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
git switch -c phase1-k3s

git add k8s/ ansible/group_vars/k3s/secrets.enc.yaml docs/runbooks/02-phase1-k3s-cluster.md

pre-commit run --all-files
git commit -m "feat(phase1): k3s HA + Cilium + MetalLB + ingress-nginx

- 3 cp + 2 wk via k3s v1.30.5+k3s1, embedded etcd HA
- Cilium 1.16 with kube-proxy replacement, native routing on cluster VLAN
- MetalLB L2 pool 10.10.20.50-99
- ingress-nginx pinned to 10.10.20.50 (target for runbook 03 cloudflared)"

git push origin phase1-k3s
```

---

## Quick reference

### Where things live

| Thing | Location |
|---|---|
| kubeconfig (operator) | `~/.kube/cucox-lab.yaml` (Mac Air) |
| kubeconfig (canonical) | `/etc/rancher/k3s/k3s.yaml` on `lab-cp01` |
| k3s join token (encrypted) | `ansible/group_vars/k3s/secrets.enc.yaml` |
| Cilium values | `k8s/cilium/values.yaml` |
| MetalLB pool | `k8s/metallb/pool.yaml` |
| ingress-nginx values | `k8s/ingress-nginx/values.yaml` |
| Ingress VIP (stable) | `10.10.20.50` |

### Diagnostic one-liners

```sh
# Cluster health at a glance.
kubectl get nodes; kubectl -n kube-system get pods; cilium status

# Cilium connectivity test (covers Pod → Pod, Pod → Service, NodePort, etc.).
cilium connectivity test --hubble=false   # heavy; run after install only.

# MetalLB VIP attribution.
kubectl -n metallb-system logs ds/speaker | tail -50

# Ingress controller errors.
kubectl -n ingress logs deploy/ingress-nginx-controller | tail -100

# Etcd quorum.
ssh ubuntu@10.10.20.21 'sudo k3s etcd-snapshot ls'
```

### Rollback ladder

1. `kubectl delete -f k8s/<component>/...` and `helm uninstall <release>`
   for component-level revert.
2. `qm rollback <vmid> phase1-k3s` per node (snapshot from Step 8.1).
3. `qm rollback <vmid> phase1-base` per node (pre-k3s baseline from
   runbook 01 Step 8) — you'll be redoing this entire runbook.
4. Full `terraform destroy` + `apply` from runbook 01.

---

## Done when

- [ ] `kubectl get nodes` shows 5 nodes, all `Ready`. The 3 cp nodes carry
      `node-role.kubernetes.io/control-plane` automatically; k3s does
      **not** auto-label agents as `worker`. Optionally label them yourself:

      ```sh
      kubectl label node lab-wk01 node-role.kubernetes.io/worker= --overwrite
      kubectl label node lab-wk02 node-role.kubernetes.io/worker= --overwrite
      ```
- [ ] `cilium status` is all green; kube-proxy replacement = `True`.
- [ ] A LoadBalancer Service gets a VIP from `10.10.20.50–.99`, ARP-pingable
      from the Mac Air.
- [ ] `curl -H Host:hello.lab.cucox.local http://10.10.20.50/` returns
      200 from the smoke-test deployment.
- [ ] Default StorageClass = `local-path`; a PVC binds inside ~5s.
- [ ] All five cluster VMs have a `phase1-k3s` snapshot.
- [ ] Both `phase1-vm-bringup` and `phase1-k3s` branches are merged to
      `main` and the decision log in `ARCHITECTURE.md` § 12 is up to date.

Next: [`03-phase2-cloudflared-tunnel.md`](./03-phase2-cloudflared-tunnel.md)
— stand up `cloudflared` on `lab-edge01`, point it at `10.10.20.50`, and
make `hello.lab.cucox.local` reachable from the public internet via the
first migrated domain (`cucox.me`, per ARCH § 6.3 and runbook 05).
