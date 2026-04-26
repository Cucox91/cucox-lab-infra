# ADR-0004 — Network: 3-VLAN design with deny-default firewall

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-25 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

The lab shares a physical network with a house LAN that includes personal
devices, a NAS, and a work laptop. The cluster will eventually run
internet-facing workloads and will be reachable from the public internet via
Cloudflare Tunnel. The threat model has two components:

1. **Keep the house network safe from the lab.** A misconfigured container,
   a vulnerable application, or a compromised workload must not be able to
   reach house devices or the NAS.
2. **Keep the internet from reaching the lab directly.** No inbound port
   forwards; all external traffic enters through the Cloudflare Tunnel.

The network runs on a Ubiquiti UCG-Max (router/firewall) with a managed
office switch and a U7 Pro AP. VLANs and inter-VLAN firewall rules are
managed in UniFi.

The Proxmox host has a 2.5 GbE PCIe NIC and is connected to the office
switch on a trunk port. Proxmox creates Linux bridges (`vmbr0` and tagged
sub-interfaces) to give each VM category its own Layer 2 segment.

Alternatives evaluated for network segmentation:

1. **Flat network — everything on Default LAN.** Simplest setup. Provides no
   isolation between lab workloads and house devices. Unacceptable given the
   lab will run internet-facing services and experimental workloads.
2. **Single lab VLAN.** One VLAN for all lab traffic. Separates lab from
   house but provides no isolation between the hypervisor management plane,
   cluster node traffic, and internet-facing services. A compromised DMZ VM
   could reach the Proxmox web UI on the same VLAN.
3. **3-VLAN design (mgmt / cluster / dmz)** — separate segments for operator
   access, cluster internals, and internet-facing edge. Deny-default
   inter-VLAN firewall with explicit allow rules. Chosen approach.

## Decision

Three VLANs on the UCG-Max, enforced at the switch and the Proxmox bridge
layer:

| VLAN | Name | Subnet | Purpose |
|---|---|---|---|
| 10 | mgmt | `10.10.10.0/24` | Proxmox host UI, k3s API server, SSH to VMs, operator clients |
| 20 | cluster | `10.10.20.0/24` | k3s node-to-node traffic, kubelet, etcd, pod routing |
| 30 | dmz | `10.10.30.0/24` | `cloudflared` egress, ingress controller front-end |

Default inter-VLAN policy: **deny**. All allow rules are explicit and minimal.

The Default LAN (house) is untouched. The NAS and personal devices remain on
Default LAN and the firewall blocks all `lab→NAS` and `lab→house` flows
except a single operator-IP exception for management access.

The Ryzen workstation's switch port is configured as a trunk with mgmt (VLAN 10)
as the native VLAN. The hypervisor is never on the house LAN.

## Rationale

### Why three VLANs rather than one or two

**mgmt vs. cluster separation** prevents a compromised cluster node from
reaching the Proxmox management plane. If a k3s worker is exploited, the
attacker lands on VLAN 20, where the only allowed routes to mgmt (VLAN 10)
are tcp/53 (CoreDNS upstream) and tcp/123 (NTP). The Proxmox web UI (tcp/8006),
SSH (tcp/22), and the k3s API (tcp/6443) are not reachable from cluster VLAN.

**dmz vs. cluster separation** contains the most-exposed component (`cloudflared`
and the ingress controller) in a segment that cannot initiate connections to
cluster internals or the mgmt plane. A vulnerability in `cloudflared` or the
ingress controller lands the attacker in the dmz, not in the cluster or on the
hypervisor.

**dmz never reaches mgmt** is an unconditional rule. The dmz VLAN is the
highest-exposure segment (it processes traffic from the public internet via
Cloudflare). If it could reach mgmt, a full-path exploit from the internet to
the Proxmox UI would require only one hop beyond the ingress. Blocking this
completely removes that path.

### Why deny-default rather than allow-default with block rules

Allow-default inter-VLAN policies create an ever-growing list of block rules.
Any new service added to the cluster is implicitly reachable from everywhere
until a block rule is written. In a lab where new workloads are added
frequently and by a single operator without a security review process, this
is a reliability risk: reachability is the default, isolation requires
ongoing maintenance.

Deny-default inverts this: new workloads are isolated by default. Access must
be explicitly granted. The allow-rule list stays short and auditable.

### NAS isolation invariant

The NAS is on Default LAN by choice and must remain fully isolated from all
lab VLANs. This is a load-bearing invariant:

- The NAS holds personal data and potentially sensitive backups.
- The cluster VLAN will eventually run workloads from the public internet
  (migrated apps). A cluster→NAS path would make the NAS reachable from
  workloads that process external traffic.
- Prohibiting this at the firewall layer is simpler and more reliable than
  relying on application-level controls.

If a future phase requires the lab to write to the NAS (e.g., for backup
storage), an ADR must be written first to reason about the security
implications before any firewall rule is added.

### Cloudflare Tunnel as the sole ingress path

No inbound port forwards on the UCG-Max. All external traffic enters via
the Cloudflare Tunnel, which is an outbound TLS connection from `lab-edge01`
(in the dmz) to the Cloudflare edge. This means:

- The UCG-Max firewall does not expose any port to the public internet.
- DDoS and scanning traffic is absorbed by Cloudflare before reaching the lab.
- Cloudflare Access policies provide an additional authentication layer in
  front of any admin UI exposed externally.

## Consequences

### Positive

- Lab workloads are fully isolated from house devices and the NAS by the
  UCG-Max firewall — not by trusting application-level controls.
- A compromised DMZ workload cannot reach the cluster internals or the
  management plane.
- A compromised cluster node cannot reach the Proxmox UI.
- No public ports exposed on the router; the internet attack surface is
  limited to what Cloudflare proxies.
- The operator (on mgmt VLAN, either via the CucoxLab-Mgmt SSID or the
  Default LAN exception) has full reach to all lab segments for
  administration.
- The allow-rule list is short, auditable, and changes rarely.

### Negative / trade-offs

- **Increased setup complexity.** Three VLANs, trunk port profiles, and
  inter-VLAN rules must be configured in UniFi before the Proxmox installer
  can be reached from the operator machine. The Phase 0 runbook documents
  the exact sequence.
- **Operator must be on mgmt VLAN to reach the cluster.** If the
  CucoxLab-Mgmt SSID is unavailable and the operator is on the house Wi-Fi,
  they rely on the Default LAN → mgmt exception rule (scoped to the
  operator's IP). This adds a dependency on the house IP being stable.
- **Future NAS integration requires an ADR.** Any `lab→NAS` access (e.g.,
  for scheduled backups) cannot be added ad-hoc; a security reasoning step
  is required. This is intentional friction.
- **dmz isolation means no shared services.** Workloads in the dmz cannot
  pull from an internal image registry or reach an in-cluster database
  directly. All dmz→cluster traffic goes through the ingress on specific
  ports. This is the correct posture but must be accounted for in
  application architecture.
