# ADR-0002 — CNI: Cilium (over Flannel default)

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-25 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

k3s ships with **Flannel** as its default CNI plugin, providing basic pod
networking out of the box with minimal configuration. The lab requires a CNI
choice before the cluster is bootstrapped, because changing CNI mid-flight is
destructive (requires a full cluster rebuild).

Criteria relevant to this decision:

- The lab's Phase 5 goal includes building and benchmarking a custom message
  broker in Go/C and comparing it against canonical implementations
  (RabbitMQ, Kafka). Intra-cluster network latency and throughput are
  measurement variables — the CNI must not be the bottleneck or add
  unnecessary noise.
- The lab should model a realistic production-grade security posture:
  NetworkPolicy enforcement, L7 policy, and per-namespace traffic isolation.
- Observability of network traffic (which pod talks to which, on which port,
  with what latency) is a day-1 requirement for an operator learning systems
  engineering — not a Phase 4 add-on.
- The CNI must support ARM nodes, as Raspberry Pi workers join in Phase 5.

Alternatives evaluated:

1. **Flannel** — k3s default. Simple, widely documented, low overhead. VXLAN
   overlay by default. No NetworkPolicy enforcement (requires a separate
   policy controller). No built-in observability.
2. **Cilium** — eBPF-based CNI. Native NetworkPolicy + L7 policy. Hubble for
   L4/L7 observability. CNCF graduated. Supports x86 and ARM.
3. **Calico** — mature CNI with strong NetworkPolicy support. BGP routing
   mode for advanced setups. Heavier operational overhead than Cilium for
   a homelab; eBPF mode is newer and less proven than Cilium's.

## Decision

**Cilium** is the CNI, installed with Flannel disabled at k3s bootstrap.

k3s is initialized with `--flannel-backend=none --disable-network-policy`;
Cilium is installed via Helm immediately after the first control-plane node
comes up. Values are stored in `k8s/cilium/values.yaml`.

## Rationale

### eBPF datapath

Cilium's eBPF datapath bypasses iptables for packet forwarding, routing
decisions, and load balancing. On a kernel supporting eBPF (5.10+, which
Proxmox 8.4 / Debian 12 provides), this translates to measurably lower
per-packet overhead compared to Flannel's iptables/VXLAN path.

For the broker benchmarking work in Phase 5, where the goal is to produce
HdrHistogram latency distributions comparing a custom broker against
RabbitMQ and Kafka, having a low-noise network layer is directly relevant.
Flannel would add variable iptables traversal overhead to every measurement.

### Hubble observability

Hubble is Cilium's built-in L4/L7 observability layer. It exposes:

- Per-flow visibility: which pod contacted which service, on which port,
  with what HTTP method/status (for L7 protocols).
- Dropped packet reasons: NetworkPolicy denies, CIDR blocks, port mismatches.
- Service maps: live topology of which workloads communicate with which.

This is directly useful for debugging microservice communication, verifying
that NetworkPolicy rules have the intended effect, and understanding the
behavior of applications being migrated from Azure. Flannel provides none
of this natively.

### NetworkPolicy + L7 policy

Cilium enforces Kubernetes NetworkPolicy natively without a separate controller.
It also supports `CiliumNetworkPolicy` for L7 rules (e.g., allow HTTP GET to
`/api/health` only). This enables a realistic zero-trust posture between
namespaces from Phase 1 — not something that gets bolted on later.

Flannel has no NetworkPolicy enforcement. Calico does, but requires a separate
installation alongside the CNI; Cilium integrates both in one Helm chart.

### CNCF graduation and ARM support

Cilium is CNCF graduated as of 2023 — the same tier as Kubernetes itself.
The ARM support (aarch64) is first-class, which is a requirement for Phase 5
when Raspberry Pi 5 workers join the cluster.

## Consequences

### Positive

- eBPF datapath reduces per-packet overhead, providing a lower-noise
  baseline for latency benchmarking in Phase 5.
- Hubble gives L4/L7 flow visibility from day one — no separate observability
  tool needed for network-level debugging.
- Native NetworkPolicy enforcement enables a real zero-trust posture between
  namespaces without a separate policy controller.
- CiliumNetworkPolicy extends standard k8s policy to L7, covering HTTP path/
  method filtering for application-layer isolation.
- Single Helm chart manages CNI + policy + observability.
- ARM-compatible for Phase 5 Pi workers.

### Negative / trade-offs

- **Higher bootstrap complexity than Flannel.** Flannel works without any
  configuration; Cilium requires Flannel to be explicitly disabled at k3s
  init time and a Helm install to follow immediately. The Phase 1 runbook
  documents this sequence.
- **Larger memory footprint.** Each node runs a `cilium-agent` DaemonSet pod.
  On VMs with 8 GB RAM this is acceptable; on Pi nodes (8–16 GB) it needs
  monitoring.
- **eBPF kernel requirements.** Requires Linux kernel 5.10+. Proxmox 8.4
  ships kernel 6.x; Pi OS ships 6.x for Pi5. Not a concern for this lab's
  hardware, but worth noting for any future heterogeneous nodes.
- **Steeper learning curve.** Cilium has more concepts than Flannel (eBPF
  maps, Hubble, CiliumNetworkPolicy CRDs). This is intentional — learning
  these concepts is part of the lab's value.
