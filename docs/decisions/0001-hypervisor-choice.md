# ADR-0001 — Hypervisor: Proxmox VE

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-25 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

The lab requires a hypervisor layer that can run multiple isolated VMs on a
single physical host (AMD Ryzen 9 5950X, 64 GB RAM, 2× 1 TB NVMe). The primary
alternatives evaluated were:

1. **Proxmox VE** — Debian-based hypervisor platform combining KVM (for VMs)
   and LXC (for containers), with a web UI, REST API, ZFS integration, and a
   Terraform provider.
2. **Bare-metal Ubuntu + k3s directly** — skip the hypervisor entirely and run
   k3s directly on the host OS, treating the physical machine as one large
   Linux node.

Key constraints and goals:

- The lab must simulate a realistic multi-node cluster (at least 3 control-plane
  + 2 worker nodes) despite having only one physical machine.
- Safe, reversible experimentation is required: the ability to snapshot and
  roll back VMs before a risky change is load-bearing for a solo operator with
  no second machine to recover from.
- The platform should be free for non-production use and have a large, active
  community producing runbooks, Terraform modules, and forum answers.
- IaC-driven VM lifecycle is a hard requirement; clicking VMs into existence is
  not acceptable past Phase 0.

## Decision

**Proxmox VE 8.4** is the hypervisor platform.

VMs are the unit of compute. Every cluster node (`lab-cp01..03`, `lab-wk01..02`,
`lab-edge01`) is a KVM VM defined in Terraform and provisioned via cloud-init.
The Proxmox host (`lab-prox01`) is managed separately and is never itself a
k3s node.

## Rationale

### Why not bare-metal Ubuntu + k3s

Running k3s directly on the host OS means the physical machine is one node. To
simulate a 5-node HA cluster you would need 5 physical machines or an
in-process simulation (kind, minikube) that trades away realism. The lab's
stated goal is to run real production workloads — multi-app, multi-database,
multi-namespace — in a realistic topology. A single-node cluster cannot
deliver that without compromising the learning objective.

Additionally, bare-metal removes snapshotting. A failed k3s upgrade, a bad
Cilium CNI change, or a misconfigured etcd compaction policy has no rewind
button. With Proxmox, a VM snapshot before any invasive operation is a 10-second
operation; recovery is equally fast.

### Why Proxmox VE specifically

- **KVM-backed VMs** give each node full CPU and memory isolation — no shared
  kernel surprises between the hypervisor and the workload.
- **ZFS-native integration** — Proxmox manages ZFS datasets and zvols directly.
  VM disks are zvols on the `tank` pool; the host OS is on `rpool`. Pool
  corruption or a failed VM disk cannot propagate across pools.
- **Terraform provider (`Telmate/proxmox`)** — a mature, widely-used provider
  that covers VM creation, cloud-init injection, disk management, and network
  configuration. The entire Phase 1 VM fleet is expressed as Terraform code.
- **REST API** — every operation available in the web UI is also available via
  API, making Claude-assisted automation and scripted runbooks practical.
- **Community size** — the Proxmox forums, r/homelab, and the broader DevOps
  community produce a large volume of tested, searchable troubleshooting
  material. This matters for a solo operator.
- **Free for non-production use** — no subscription required for the core
  platform. The enterprise repository (for LTS point-release updates) is not
  used; the no-subscription repository is configured instead.

### Why Proxmox 8.4 over 9.x

Proxmox 9.x was available at install time. 8.4 was chosen for ecosystem
maturity: the Terraform provider, community runbooks, and third-party
integrations are tested against the 8.x line. The 9.x tooling ecosystem was
still catching up. The lab values stability and searchable documentation over
being on the latest version. Migration to 9.x is deferred until the ecosystem
matures.

## Consequences

### Positive

- Realistic 5-node HA k3s cluster on one physical machine.
- VM-level snapshotting enables safe, reversible experimentation.
- ZFS pools provide data integrity, compression, and copy-on-write snapshots
  for both the hypervisor and VM workloads.
- Terraform-driven VM lifecycle from Phase 1 onward — no manual VM creation.
- Large community means most problems have a documented solution.

### Negative / trade-offs

- **Proxmox is another layer to operate.** Host OS updates, Proxmox package
  upgrades, and ZFS pool health are additional operational responsibilities.
  Mitigated by keeping the host simple: no workloads run directly on
  `lab-prox01`; it is a VM factory only.
- **Single point of failure.** The physical host going down takes the entire
  cluster down. Acceptable for a Phase 0–4 single-site lab; Phase 5 may
  introduce Pi workers as partial mitigation.
- **GPU passthrough complexity.** The RTX 3080 in the host will be passed
  through to a dedicated VM in a future phase. This requires AMD-Vi / IOMMU
  configuration and VFIO driver binding on the host, adding one-time
  setup complexity. Proxmox has well-documented procedures for this.
- **RAM headroom is tight.** 6 VMs × average ~10 GB = ~60 GB committed
  against 64 GB physical, leaving ~4 GB for Proxmox + ZFS ARC. ARC is
  capped at 8 GB system-wide. If memory pressure shows up, one control-plane
  VM may be dropped (see § 12 in `ARCHITECTURE.md`).
