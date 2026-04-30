# ADR-0012 — VLAN model on Proxmox: traditional Linux VLAN over VLAN-aware bridge

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-29 |
| **Deciders** | Raziel |
| **Supersedes** | — |
| **Related** | [ADR-0004](./0004-network-vlan-design.md) (the 3-VLAN design this implements) |

## Context

ARCHITECTURE.md § 3.1 specifies that the Proxmox host carries three lab
VLANs (mgmt/cluster/dmz) over a single trunk port from the office switch,
exposed as three logical interfaces:

```
[Proxmox vmbr0]
      ├── vmbr0    → mgmt    (host + mgmt-VLAN VMs)
      ├── vmbr0.20 → cluster (k3s nodes)
      └── vmbr0.30 → dmz     (cloudflared, ingress)
```

Linux + Proxmox supports two practical ways to carry multiple VLANs over
one physical NIC:

**Pattern A — VLAN-aware bridge.** A single Linux bridge with
`bridge-vlan-aware yes`. VMs attach with `--net0 bridge=vmbr0,tag=N` and
the bridge's per-port PVID/VID configuration policies tagging.

**Pattern B — Traditional Linux VLAN.** One Linux bridge per VLAN. Each
non-native bridge is fed by a kernel VLAN sub-interface of the physical
NIC (`enp5s0.20`, `enp5s0.30`, …) which adds/strips the 802.1Q tag.
VMs attach to the bridge that matches their VLAN with no `tag=N`.

The Phase 0 runbook (`00-phase0-proxmox-bootstrap.md` § 7.1) initially
implemented Pattern A. This produced a real failure during Phase 1 §3.5
(probe-clone): Mac Air → host (10.10.10.10) worked, Mac Air → VM
(10.10.10.99 on the same VLAN) did not. Diagnosis:

```sh
$ bridge vlan show
port              vlan-id
enp41s0           1 PVID Egress Untagged
                  10
                  20
                  30
vmbr0             1 PVID Egress Untagged
tap999i0          10 PVID Egress Untagged
```

The host's IP and the VM ended up on different internal bridge segments
(VID 1 vs VID 10) because the upstream switch's native-VLAN mapping
delivers VLAN-10 traffic untagged on the trunk, which the VLAN-aware
bridge assigned to VID 1 by default. Mitigations attempted (`bridge-pvid 10`,
per-port `post-up` PVID rewrites) either failed to propagate consistently
across `ifupdown` versions or required defensive scaffolding that the
architecture document never asked for.

## Decision

The lab uses **Pattern B — traditional Linux VLAN, one bridge per VLAN.**

Final `/etc/network/interfaces` shape (NIC name varies per host —
substitute as appropriate):

```ini
auto enp5s0
iface enp5s0 inet manual

auto enp5s0.20
iface enp5s0.20 inet manual

auto enp5s0.30
iface enp5s0.30 inet manual

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.10/24
    gateway 10.10.10.1
    bridge-ports enp5s0
    bridge-stp off
    bridge-fd 0

auto vmbr20
iface vmbr20 inet manual
    bridge-ports enp5s0.20
    bridge-stp off
    bridge-fd 0

auto vmbr30
iface vmbr30 inet manual
    bridge-ports enp5s0.30
    bridge-stp off
    bridge-fd 0
```

VMs attach with `--net0 virtio,bridge={vmbr0|vmbr20|vmbr30}` — no
`tag=N`. The kernel VLAN sub-interface tags egress unconditionally;
the upstream switch's `lab-trunk` profile (native = mgmt 10, tagged 20+30)
maps untagged-on-wire to VLAN 10 for `vmbr0` traffic.

## Rationale

### Architecture-implementation alignment

ARCHITECTURE.md § 3.1's notation (`vmbr0`, `vmbr0.20`, `vmbr0.30`) is the
traditional Linux VLAN naming convention. Pattern B matches the
architecture document literally. Pattern A would require either rewriting
the architecture or operating with persistent drift between design and
implementation. The lab is supposed to be a teaching artifact (per
ADR-0008); silent drift between design and reality undermines that.

### Operational reliability

Pattern A relies on per-port PVID/VID configuration, which:

- Defaults differ across `ifupdown` / `ifupdown2` versions — `bridge-pvid`
  on the bridge stanza sometimes propagates to ports, sometimes doesn't.
- Misconfigurations are silent until you try to send traffic across
  segments.
- Debugging requires reading `bridge vlan show` and reasoning about
  internal bridge VLANs, which is one more abstraction layer than is
  necessary.

Pattern B has no such configuration. The kernel VLAN device adds the tag
unconditionally; the bridge is a vanilla L2 switch with no VLAN logic.
Failure modes are immediate and obvious (bridge missing, sub-interface
not up).

### Stronger tag-injection resistance

In Pattern A, a malicious or misconfigured VM can in principle send
arbitrary tagged frames into the bridge; correct behavior depends on the
bridge enforcing per-port VID restrictions. In Pattern B, the kernel
VLAN device adds VLAN N **on top of** whatever the VM sent, producing a
double-tagged Q-in-Q frame. The outer tag is always correct. The only
remaining VLAN-hopping risk is upstream switch tag-stripping, which is
identical between patterns (and not enabled on the UCG-Max / UniFi
switch by default).

### Failure-mode visibility

Forgetting `tag=20` in Pattern A places a VM silently on the untagged
segment, which on the lab's trunk port = mgmt VLAN 10. Accidental
privilege escalation, no warning.

In Pattern B the analogous mistake (`bridge=vmbr0` instead of `vmbr20`)
is visible in `qm config`, in Terraform state, in `ip link`, and in any
runbook that lists per-VM bridges. Same root cause class, much higher
discoverability.

### What we give up

- **Slightly more interfaces to manage** — six logical interfaces (NIC,
  two sub-interfaces, three bridges) instead of one VLAN-aware bridge.
  At three VLANs this is a non-issue; at twenty it would matter.
- **Pattern A is more common in current Proxmox tutorial gravity** — the
  tutorial population skews newer, and `bridge-vlan-aware` is the default
  in fresh Proxmox installs as of 8.x. Counterargument: the older,
  traditional pattern has more battle-tested operational guidance and
  predictable failure modes.

## Consequences

### Positive

- ARCH § 3.1 implementation matches its diagram exactly.
- No bridge-VLAN configuration to drift across `ifupdown` versions.
- Kernel-enforced VLAN tag integrity at the host (egress).
- Misconfigurations are immediately visible in `qm config` / Terraform.
- Bridge VLAN debugging is reduced to "is the right bridge present, is
  the sub-interface up, does it ARP" — no per-port internal VLAN reasoning.

### Negative / trade-offs

- Six logical interfaces vs one. Acceptable at 3 VLANs.
- Adding a fourth lab VLAN later requires three edits to
  `/etc/network/interfaces` (NIC sub-interface + bridge stanza + bridge
  port) instead of one (`bridge-vids` extension). Fine — adding a VLAN
  is a deliberate event, not something to streamline.

### What changes in dependent runbooks/code

- `docs/runbooks/00-phase0-proxmox-bootstrap.md` § 7.1 implements this
  ADR (the three-bridge config above).
- `docs/runbooks/00-phase0-proxmox-bootstrap.md` § 9.1 verifies it
  (`bridge vlan show` should be empty; `ip -br link show type bridge`
  shows three bridges).
- `docs/runbooks/01-phase1-vm-bringup.md` § 3.2, § 3.5, § 5.1, § 5.2
  use `bridge=vmbr0|vmbr20|vmbr30` directly with no `tag=N`. The
  Terraform `vms` map carries a `bridge` field per VM instead of `vlan`.

### Closing the deviation history

Phase 0 had a Pattern-A draft that was committed and run by the operator.
The corrective sequence:

1. Identify the symptom during Phase 1 § 3.5.
2. Diagnose with `bridge vlan show`.
3. Stabilize (revert any speculative `bridge-pvid` edits).
4. Replace with the Pattern B config in this ADR.
5. Update Phase 0 § 7.1 to teach Pattern B from the start.
6. Add Phase 0 § 9.1 verification so future runs catch any regression.

This ADR exists to record (a) why Pattern B is the chosen model, and
(b) the institutional memory of what went wrong with Pattern A so we
don't re-introduce it during a future "let me simplify this" pass.

## Alternatives considered

### Pattern A — VLAN-aware bridge (with `bridge-pvid 10` + per-port PVIDs)

Could be made to work with `post-up bridge vlan add ... pvid untagged`
hooks for both the bridge self port and the trunk port. Rejected because:

- Requires defensive per-port scaffolding that the architecture document
  doesn't ask for.
- Behavior depends on `ifupdown` / `ifupdown2` version quirks.
- Doesn't match ARCH § 3.1's notation.
- No operational benefit to offset the cost.

### Pattern A — VLAN-aware bridge with `bridge-pvid 10` only

What was tried first. Doesn't propagate to the trunk port reliably across
ifupdown versions; broke host reachability when the bridge self moved to
PVID 10 but `enp41s0` stayed at PVID 1. Symptom was "host unreachable
from Mac Air after the change." Rejected on operational grounds.

### Switch port profile change (drop native VLAN, all tagged)

Would force the host to use an explicit `vmbr0.10` interface. Cleaner in
some senses but requires changes outside the host (UniFi config), and
Phase 0 already committed to `lab-trunk: native=mgmt(10)` for a reason
(operator can plug a non-VLAN-aware host into the Ryzen port and get
mgmt access, useful for recovery). Rejected — the trunk profile is fine
as-is; the model on the Proxmox side is what changes.

### `OVSBridge` (Open vSwitch)

OVS supports more sophisticated VLAN behaviors (per-port trunks/access,
flow rules, VXLAN, etc.). Rejected for this lab — meaningful overhead
for zero current benefit; reintroducing dependencies on a project the
homelab community isn't broadly invested in. Re-evaluate if Phase 5
broker-network experiments need flow-level control.

## References

- [ADR-0004](./0004-network-vlan-design.md) — the 3-VLAN design this
  ADR implements.
- ARCHITECTURE.md § 3.1 (topology), § 3.4 (switch port profiles).
- `docs/runbooks/00-phase0-proxmox-bootstrap.md` § 7.1, § 9.1.
- `docs/runbooks/01-phase1-vm-bringup.md` § 3.2, § 3.5, § 5.1, § 5.2.
- Proxmox wiki: [Network Configuration — VLAN](https://pve.proxmox.com/wiki/Network_Configuration#_vlan_802_1q) (Pattern B is the "VLAN with subinterfaces" section).
