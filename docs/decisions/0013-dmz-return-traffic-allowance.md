# ADR-0013 — DMZ stateful return traffic to mgmt is permitted

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-29 |
| **Deciders** | Raziel |
| **Supersedes** | — |
| **Amends** | ADR-0004 (clarifies the `dmz → mgmt: none` rule) |

## Context

ADR-0004 establishes the 3-VLAN deny-default firewall posture and explicitly
calls out:

> **dmz never reaches mgmt** is an unconditional rule. The dmz VLAN is the
> highest-exposure segment (it processes traffic from the public internet via
> Cloudflare). If it could reach mgmt, a full-path exploit from the internet
> to the hypervisor would be possible.

That paragraph was written when the firewall posture was sketched, before
the operational reality of stateful firewalls was made explicit in the doc.
The implementation (UniFi 9.x Zone-Based Firewall on a UCG-Max) raised the
question during Phase 1 edge01 bringup:

- ARCH §3.3 also says `mgmt → dmz: all`. The operator must reach cloudflared
  / ingress for debugging.
- For SSH from mgmt to dmz to actually work, the SYN-ACK must traverse
  `dmz → mgmt` on the return path.
- UniFi 9.x does not auto-create return-traffic allow rules for non-default
  zone pairs. The `Lab-DMZ → Lab-Mgmt` matrix cell defaults to deny and
  drops the SYN-ACK.
- Therefore, `mgmt → dmz: all` (forward) without an Established/Related
  return rule on `dmz → mgmt` is functionally useless: TCP three-way
  handshake never completes.

The original ARCH §3.3 entry `dmz | mgmt | none` was ambiguous: did it mean
"no L3 packets in any direction at any state" (literal interpretation), or
"no new connections initiated from dmz" (industry-standard interpretation
for stateful firewalls)?

This ADR makes the choice explicit and writes it into ARCH §3.3.

Three options were evaluated:

1. **Literal interpretation: zero `dmz → mgmt` packets, ever.** The
   `mgmt → dmz: all` forward rule becomes useless. Operator debugging of dmz
   VMs requires alternative paths: Proxmox NoVNC console, `qm terminal`
   serial console, `qm guest exec` via qemu-guest-agent, or Tailscale
   (per ADR-0011) installed on the dmz VM as out-of-band access.
2. **Stateful interpretation: allow Established+Related from `dmz → mgmt`,
   block New.** Operator-initiated SSH/HTTPS from mgmt to dmz works.
   New connections from dmz to mgmt remain blocked; the threat model in
   ADR-0004 (internet → dmz → mgmt pivot) is preserved at the
   New-connection layer. **Chosen.**
3. **Bidirectional allow with no state distinction.** Rejected without
   detailed analysis — defeats the whole point of having dmz as a
   separate zone.

## Decision

`dmz → mgmt` permits **stateful return traffic only**. Specifically:

- A `Lab-DMZ → Lab-Mgmt: Allow` rule with `Match State = Established, Related`
  exists in the UniFi Zone-Based Firewall, ordered above any catch-all
  `Block All` in the same cell.
- A `Lab-DMZ → Lab-Mgmt: Block` rule (no state qualifier, or `Match State =
  New`) exists below the Allow Return rule.
- New TCP connections initiated from a dmz host to any mgmt IP are dropped
  at the SYN — including, but not limited to, attempts to reach
  `10.10.10.10:8006` (Proxmox UI), `10.10.10.x:6443` (k3s API), and
  `10.10.10.x:22` (SSH to mgmt-side hosts).

This is the same pattern already in use for `cluster → mgmt`, and it brings
dmz into symmetry with cluster's posture.

The change to ARCH §3.3.1 makes the convention explicit at the table level:
all `X → Y: ...` entries refer to **new connections**; return traffic is
governed by §3.3.5.

## Rationale

### Why this preserves ADR-0004's threat model

The threat ADR-0004 names — *internet → dmz → mgmt pivot* — requires the
attacker to **initiate** a new connection from compromised dmz code into
mgmt. Established/Related return traffic does not enable that:

- The attacker cannot open a fresh TCP connection to the Proxmox UI: SYN
  blocked at the New layer.
- The attacker cannot scan the mgmt VLAN for services: SYN blocked.
- The attacker cannot spoof source IPs to look like return traffic for a
  flow that doesn't exist: conntrack has no matching entry; packet dropped.

What the attacker **can** do, given Established/Related allows back:

- Send arbitrary bytes back over an SSH session the operator already opened.
  This is no worse than any SSH client trusting any SSH server: the operator
  already runs a shell on the (potentially-compromised) dmz host the moment
  they SSH in. The lateral threat is identical with or without this rule.

The asymmetric posture is the standard zero-trust DMZ model: clients in
the trusted zone can reach into the DMZ and receive responses; nothing
in the DMZ can initiate toward the trusted zone. This ADR brings the
implementation in line with that standard.

### Why not Path 1 (literal zero-packets, all-out-of-band)

Path 1 is more pedagogically interesting in a learning lab: the operator
*feels* the strict-DMZ posture every time they debug. But the practical
costs are real:

- Every dmz interactive session is NoVNC in a browser — slow, no
  copy/paste history, no terminal multiplexer.
- `qm terminal` works but cloud-init never sets a console password by
  default; setting one for every troubleshooting session is friction
  that encourages the operator to leave passwords lying around.
- `qm guest exec` requires qemu-guest-agent to be running. If the bug
  the operator is debugging is exactly that the agent is broken (a real
  failure mode, observed in this lab during Phase 1), the option is gone.
- Tailscale-as-DMZ-access (per ADR-0011) is a workaround, not a security
  improvement. Tailscale's stateful tunnel from dmz to mgmt is
  functionally equivalent to a UniFi-allowed Established/Related flow,
  just routed differently and with a SaaS dependency.

The security delta of Path 2 over Path 1 is "an attacker on dmz can send
malicious data back to an operator's SSH client during an already-open
session." The operational delta is "the operator can SSH directly to dmz
hosts." For a single-operator lab, that trade is heavily in favor of
operability.

### Why not Path 3 (full bidirectional allow)

Trivially defeats the segmentation. Not seriously considered.

### Why this is symmetric with cluster

`cluster → mgmt` has carried Established+Related return permissions since
Phase 1 brought up the cluster VMs (the SSH-from-Mac-Air-to-cluster-nodes
verification step in runbook 01 §7 only worked because of this). cluster
was never a debate because the threat-model concern in ADR-0004 was
specifically about dmz, not cluster. Bringing dmz into the same shape
removes a special case rather than adding one.

## Consequences

### Positive

- Operator can SSH directly to dmz hosts from mgmt (Mac Air on
  CucoxLab-Mgmt SSID). Standard tooling works: `ssh ubuntu@10.10.30.21`,
  `scp`, `rsync`, ProxyJump, etc.
- `mgmt → dmz: all` now functions as written in ARCH §3.3.1.
- Symmetric implementation across cluster and dmz; no special case to
  remember.
- ARCH §3.3 unambiguous on stateful semantics — future readers (and
  future-Raziel) won't have to re-derive the convention.
- No new tooling required. No SaaS dependency added. The Tailscale path
  for remote access (ADR-0011) is preserved for *off-LAN* operator access
  but is not load-bearing for *on-LAN* debugging of dmz.

### Negative / trade-offs

- An attacker who compromises a dmz host can send arbitrary bytes back
  over operator-initiated SSH/HTTPS sessions. Not exploitable for
  pivoting; relevant only if the operator's local SSH/curl/etc. has a
  parser-side vulnerability triggered by malicious server data.
  Mitigation: keep operator client software up to date (already a
  baseline expectation).
- The `dmz → mgmt` zone-pair cell now contains an Allow rule, which
  could be misconfigured during future edits. Mitigation: the Match
  State qualifier is the single load-bearing field. Any future edit
  that removes or broadens it must reference this ADR.
- A future stricter posture (genuine zero-packet `dmz → mgmt`) is now
  one ADR amendment away rather than the current state. Mitigation: if
  the lab graduates from learning into production, this ADR can be
  superseded by an ADR-0013-A that adopts Path 1 with documented
  alternative-debugging tooling investment.

### Operational checklist when this rule is in effect

- [x] `Lab-DMZ → Lab-Mgmt` cell contains `Allow ESTABLISHED+RELATED` rule
      ordered above `Block All`.
- [x] No allow rule in the same cell uses `Match State = New` (or omits
      the state qualifier in a way that defaults to "any").
- [x] `Lab-DMZ → Lab-Cluster` cell follows the same pattern (return
      traffic for `cluster → dmz: tcp/443, tcp/7844` flows).
- [x] ARCH §3.3.1, §3.3.4, §3.3.5 reference this ADR.
- [ ] Review revisited when Phase 4 egress filtering lands; verify the
      stricter `dmz → External` constraints don't create a new asymmetry
      with this rule.

## Out of scope for this ADR

- **`cluster → dmz` and reverse.** Already in §3.3 with their own
  port-specific allows; the return-traffic shape is part of §3.3.5 and
  inherits the same convention. No separate ADR needed.
- **`Default LAN → mgmt` operator-IP exception.** Single-IP allowlist;
  stateful semantics are implicit in any IP-restricted rule.
- **Tailscale ACLs (ADR-0011).** Operate on the tailnet, not the
  UCG-Max zone-pair. Independent posture.
