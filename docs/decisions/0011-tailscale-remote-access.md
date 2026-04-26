# ADR-0011 — Tailscale as the operator remote-access plane

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-26 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

ADR-0004 establishes that the lab has **no inbound port forwards on the
UCG-Max** and that public-facing application traffic enters exclusively through
the Cloudflare Tunnel from the dmz VLAN. That covers ingress for *services*,
but it deliberately leaves a gap: there is no path for the **operator** to
reach the management plane (Proxmox UI, k3s API, SSH to VMs) when not on the
home network.

The operator role has needs that do not fit the Cloudflare Tunnel model:

- **Access to admin UIs that should never be on the public internet.** The
  Proxmox web UI (tcp/8006), the k3s API server (tcp/6443), and SSH (tcp/22)
  to any cluster node must not be reachable through Cloudflare or any other
  public path, regardless of authentication in front. Reducing the attack
  surface to "not reachable" is stronger than "reachable but authenticated."
- **Lateral access into the mgmt VLAN.** Cloudflare Tunnel only delivers
  traffic into the dmz VLAN by design (ADR-0004). The operator needs to
  arrive in the mgmt VLAN, which has the firewall allow-rules required to
  reach the rest of the cluster.
- **CGNAT / NAT-traversal-friendly.** The home connection may sit behind
  CGNAT in the future or for travel hotspots; any solution that depends on
  a public-routable home IP is fragile.
- **Independent of being on the home network.** The Default LAN → mgmt
  exception in ADR-0004 only helps when the operator is *on the home Wi-Fi*.
  It does nothing for travel.

A secondary need has been raised: a **general-purpose exit node** for routing
personal traffic from untrusted networks (cafe Wi-Fi, hotel networks) back
through home internet. This is a personal-utility need, not a lab-operator
need, but the same overlay technology can serve both if scoped carefully.

Alternatives evaluated:

1. **Open SSH / web ports through the UCG-Max with IP allowlists.** Violates
   the "no inbound port forwards" invariant in ADR-0004. IP allowlists are
   fragile when the operator is on rotating residential / mobile IPs.
2. **WireGuard with a manual peer config on the UCG-Max.** Requires either
   an inbound port (violates the invariant) or a self-hosted relay. Manual
   key distribution. No identity-aware ACLs. Acceptable but high-friction.
3. **Cloudflare Access in front of the Proxmox UI exposed via Cloudflare
   Tunnel.** Brings admin UI traffic into the public internet path. Even
   with strong auth, it widens the attack surface and creates a CF-account
   compromise dependency for hypervisor access. Rejected.
4. **Self-hosted Headscale (open-source Tailscale control plane).** Equivalent
   data plane to Tailscale. Good long-term direction for full self-hosting,
   but adds a control-plane availability dependency that has to be solved
   *before* the lab itself is reachable — chicken-and-egg if Headscale lives
   in the lab. Defer to a later phase.
5. **Tailscale (managed control plane, free tier).** Identity-aware overlay
   with WireGuard data plane, NAT-traversal via DERP relays, ACLs, MagicDNS,
   and Tailscale SSH. Free for personal use up to 100 devices. Chosen.

## Decision

Tailscale is adopted as the **single operator remote-access plane** for the
lab. No other inbound admin path will be opened.

### Topology

The tailnet contains three role categories of devices, distinguished by tag:

| Tag | Role | Devices |
|---|---|---|
| `tag:operator` | Operator clients — full admin reach | MacBook Air; future operator devices |
| `tag:lab-host` | Lab management endpoints — Proxmox UI, SSH, k3s API | Proxmox host (Phase 1); LXC subnet router (Phase 2) |
| `tag:lab-exit` | Personal-traffic exit node only | Dedicated Pi 5 (Phase 3); not the Proxmox host |

Tailscale runs on:

- **Phase 1 — directly on the Proxmox host.** Fastest path to remote admin.
  No subnet routing, no exit node. This is the immediate ASAP requirement.
- **Phase 2 — a dedicated LXC on Proxmox (`lab-router01`)** advertising the
  mgmt VLAN (`10.10.10.0/24`) as a subnet route. Once active, the host's
  Tailscale install can be retired or kept as a backup ingress.
- **Phase 3 — a dedicated exit node** on one of the Pi 5s. Separate device,
  separate tag, separate ACL scope. Not co-located with the admin role.

### Subnet routing scope

The subnet router advertises **only `10.10.10.0/24` (mgmt VLAN)**. It does
**not** advertise `10.10.20.0/24` (cluster) or `10.10.30.0/24` (dmz).

The ADR-0004 segmentation continues to be enforced at the UCG-Max firewall.
A tailnet operator who lands on mgmt has the same reach as a local operator
on mgmt: explicit allow-rules to cluster, none to dmz beyond ingress paths.
Tailscale does not pierce VLAN segmentation; it only delivers the operator
into mgmt.

If a future need arises to subnet-route additional VLANs, an ADR amendment
is required first. This is intentional friction.

### ACL skeleton

The tailnet ACL is authored as code (HuJSON) and committed to this repo
under `tailscale/policy.hujson` once the policy is exported from the admin
console. The shape:

```jsonc
{
  "tagOwners": {
    "tag:operator":  ["autogroup:admin"],
    "tag:lab-host":  ["autogroup:admin"],
    "tag:lab-exit":  ["autogroup:admin"]
  },

  "acls": [
    // Operator → lab management endpoints.
    // 22 = SSH, 8006 = Proxmox UI, 6443 = k3s API server.
    { "action": "accept",
      "src":    ["tag:operator"],
      "dst":    ["tag:lab-host:22,8006,6443"] },

    // Operator → exit node (route approval is separate, see autoApprovers).
    { "action": "accept",
      "src":    ["tag:operator"],
      "dst":    ["tag:lab-exit:*"] }

    // Default-deny everything else. No tag-to-tag traffic between
    // tag:lab-host and tag:lab-exit; no cross-tenant flows.
  ],

  "ssh": [
    // Tailscale SSH: identity-bound, key-less. Only operator → lab-host.
    { "action":  "accept",
      "src":     ["tag:operator"],
      "dst":     ["tag:lab-host"],
      "users":   ["root", "raziel"] }
  ],

  "autoApprovers": {
    // Subnet routes the lab-host LXC may advertise without manual approval.
    "routes": {
      "10.10.10.0/24": ["tag:lab-host"]
    },
    // Exit-node advertisement requires explicit auto-approval too.
    "exitNode": ["tag:lab-exit"]
  },

  "nodeAttrs": [
    // Force key expiry on operator devices. Long-lived lab nodes opt out.
    { "target": ["tag:operator"], "attr": ["funnel"] }
  ]
}
```

The default-deny posture mirrors ADR-0004's firewall philosophy: nothing is
implicitly reachable on the tailnet. Every flow is named.

### Tailscale SSH

Tailscale SSH is enabled on every `tag:lab-host` node. SSH authentication is
delegated to tailnet identity instead of ssh-keys-on-disk. Reasoning:

- Eliminates a class of key-distribution and key-rotation problems.
- ACLs in code, version-controlled, peer-reviewable in PRs.
- Tailscale identity is bound to SSO; revoking the operator account
  immediately revokes shell access.
- Session logging is centralized in the Tailscale admin console.

Traditional `~/.ssh/authorized_keys`-based SSH on `0.0.0.0:22` is **not**
exposed on any other interface; sshd binds to localhost only on Tailscale-SSH
hosts, or sshd's `Match` config restricts password/key auth to the LAN
range. (Exact mechanism specified in the runbook.)

### Exit-node policy

The exit node is **opt-in per session** on operator devices. Operator devices
do not auto-route their default traffic through home — that would be wasteful
on home Wi-Fi and would break LAN-discovery use cases. The operator runs
`tailscale set --exit-node=<node>` only when actively on an untrusted network.

The exit node advertises both IPv4 and IPv6 forwarding. Without IPv6
forwarding, dual-stack sites break weirdly when the exit node is selected.

The exit node is **not** the same device as the Proxmox host or the subnet
router. Co-locating personal-traffic exit with hypervisor admin would mix
two postures: one needs to be reachable to anyone on the public internet
via DERP for relay, the other should be reachable only by `tag:operator`.
Separate devices, separate ACL surface.

### Key expiry & device approval

- **Key expiry: 90 days** on `tag:operator` devices. Reauthentication is a
  small periodic friction in exchange for bounded blast radius if a device
  is lost.
- **Key expiry: disabled** on `tag:lab-host` and `tag:lab-exit`. These are
  unattended infrastructure; a forced re-auth at 03:00 UTC during a power
  outage is worse than the marginal security gain.
- **Device approval: enabled** at the tailnet level. New devices joining
  the tailnet must be approved in the admin console before they receive
  routing. Defends against leaked auth keys and stolen reusable invites.

### MagicDNS & DNS strategy

MagicDNS is enabled on the tailnet. Operator devices accept Tailscale DNS;
hosts in `tag:lab-host` and `tag:lab-exit` **do not** accept Tailscale DNS
(`--accept-dns=false`). Reasoning:

- Operator side: `ssh proxmox` and `https://proxmox:8006` from the MacBook
  resolve via MagicDNS. No `/etc/hosts` editing.
- Host side: the Proxmox host's DNS is configured by the network design
  (see ADR-0004; CoreDNS upstream for cluster names). Tailscale taking over
  `/etc/resolv.conf` on the host could shadow the cluster DNS path. Safer
  to leave host DNS untouched.

Once the LXC subnet router exists (Phase 2), the operator can also reach
mgmt VLAN hosts by their LAN IP (`10.10.10.x`). MagicDNS handles the friendly
names; LAN IPs handle anything not in MagicDNS.

### Out of scope for this ADR

- **Public app traffic** — handled by ADR-0004 / Cloudflare Tunnel. No
  application service is exposed via Tailscale Funnel; Funnel will be
  disabled at the tailnet level (`nodeAttrs` denies `funnel`).
- **Headscale migration** — deferred. When the lab is mature enough that a
  control-plane outage is something Raziel wants to own, an ADR will
  re-evaluate.
- **Tailscale + k8s integration** (`tailscale-operator`) — not in scope. The
  k3s API is reached via the operator's tailnet path into mgmt, then via
  `kubectl` to the API on `tag:lab-host:6443`. Per-namespace tailnet
  exposure can be considered in a later ADR if a use case appears.

## Rationale

### Why Tailscale (managed) and not Headscale today

Tailscale's free tier covers the lab's full requirement set: 100 devices,
unlimited subnet routes, ACLs, MagicDNS, exit nodes, Tailscale SSH. The
data plane is already self-hosted (peer-to-peer WireGuard between operator
and lab); only the **coordination plane** (key exchange, ACL distribution)
runs on Tailscale's servers.

A Headscale-on-the-lab control plane creates a hard dependency: the operator
cannot reach the lab to fix Headscale if Headscale itself is down. That is
exactly the wrong direction for an admin path. Headscale is the right answer
once the lab is running on highly-available infrastructure that is *not* the
same infrastructure that depends on Headscale to be reachable. That is
explicitly post-Phase-2.

### Why default-deny ACLs from day one

The lab's network design (ADR-0004) commits to default-deny precisely because
allow-default scales poorly under "single operator adds workloads
frequently." The same logic applies to the tailnet ACL. Starting with the
Tailscale default `"action": "accept"` policy and tightening later requires
either remembering every device added in the meantime or accepting an
indeterminate audit gap.

### Why the exit node is a separate device

The exit node will be advertised — by definition — as a routing target. ACLs
restrict who can *use* it, but its existence as a tailnet node is more
exposed than a strictly internal admin endpoint. Keeping it on a Pi 5 with
no other lab role means a compromise of the exit node is a compromise of a
single-purpose device, not the hypervisor that runs every workload.

The Pi 5 also has appropriate idle power draw for an always-on personal
utility (~3–5 W) compared to running it inside a VM on the Ryzen workstation
(which would require keeping the workstation powered when otherwise idle).

### Why the subnet router gets its own LXC instead of staying on the host

Long term, the host should stay narrow: it runs the Proxmox kernel and
storage layer, and that's it. Network-overlay software, container runtimes,
and any package that pulls in systemd unit files are better off in a
dedicated LXC that can be rebuilt without touching the hypervisor.

The Phase 1 host install exists only because the LXC cannot be created
before the host is up and the operator is remote. As soon as the LXC is
running, the host install becomes optional.

## Consequences

### Positive

- The Proxmox UI, k3s API, and SSH are reachable from anywhere the operator
  has an internet connection — without opening any inbound port at the
  UCG-Max, and without exposing admin UIs to Cloudflare's edge.
- ADR-0004's "no inbound port forwards" invariant remains intact.
- Identity-aware access control: revoking the operator's tailnet account
  revokes lab access immediately, with no per-host key removal.
- ACLs are version-controlled (HuJSON in this repo); operator-access changes
  are reviewable in PRs.
- The exit-node need is solved on a separate device, with separate ACLs,
  without expanding the trust surface of the hypervisor.
- Works behind CGNAT, restrictive corporate Wi-Fi, and most hotspot NATs
  via DERP relays. Travel-friendly.

### Negative / trade-offs

- **Dependency on Tailscale's coordination plane.** A Tailscale outage
  prevents new sessions from establishing (existing sessions continue).
  Mitigated by keeping a long-running tmux/SSH session on critical work
  during travel and by accepting that a lab that depends on a coordination
  service is appropriate at this maturity level. Headscale migration is
  the long-term answer.
- **Tailscale SaaS holds metadata.** Device names, public keys, ACL
  policies, and connection logs live in Tailscale's account. Threat model:
  acceptable for a personal lab; documented here so it's a deliberate
  choice rather than a forgotten one.
- **The MacBook becomes a credential.** Anyone with the MacBook + screen
  unlock has tag:operator reach. Mitigations: FileVault, screen-lock
  timeout ≤ 5 min, key expiry 90 days, device approval enabled.
- **Subnet routing is one more thing to debug** when something breaks.
  When `kubectl` from the MacBook fails, the question is now "is it the
  k3s API, the Tailscale subnet route, the UCG-Max firewall, or the cluster
  CNI." A short troubleshooting flow is included in the Phase 2 runbook.
- **Tailscale SSH replaces a familiar workflow.** Existing SSH muscle
  memory (`~/.ssh/config`, ProxyJump, key files) doesn't transfer directly.
  This is a learning cost; the runbook documents the equivalents.

## Phased rollout

| Phase | Goal | Runbook |
|---|---|---|
| 1 | Proxmox host on tailnet — web UI + SSH from anywhere | `06-tailscale-proxmox-host-bootstrap.md` |
| 2 | LXC subnet router advertising mgmt VLAN; retire host install | `07-tailscale-lxc-subnet-router.md` (TBD) |
| 3 | Pi 5 exit node with ACL-scoped opt-in routing | `08-tailscale-exit-node.md` (TBD) |
| 4 | Tailnet ACL exported to repo as code; review cadence established | `09-tailscale-acl-as-code.md` (TBD) |
| Future | Headscale evaluation — ADR amendment if adopted | — |
