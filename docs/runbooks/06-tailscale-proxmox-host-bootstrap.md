# Runbook 06 — Tailscale Phase 1: Proxmox host on the tailnet

> **Goal:** End the runbook able to reach the Proxmox web UI
> (`https://proxmox:8006`) and SSH into the Proxmox host from the MacBook
> Air *while not on the home network*, via Tailscale.
>
> **Estimated time:** 20–30 minutes.
>
> **Operator:** You, on the home network for the install. Once done, you can
> verify from any other network (or your phone's hotspot).
>
> **Reference:** [ADR-0011 — Tailscale as the operator remote-access plane](../decisions/0011-tailscale-remote-access.md).

This is Phase 1 of the Tailscale rollout. It is deliberately **minimal**:
no subnet routing, no exit node, no ACL-as-code yet. Those are later phases.
The single objective is: make Proxmox reachable remotely.

---

## Prerequisites

Before starting:

- **Tailnet exists.** A free Tailscale account at <https://login.tailscale.com>.
  The MacBook Air is already enrolled (per the conversation that kicked
  this off).
- **Proxmox host is up and on mgmt VLAN** per Runbook 00. You can reach it
  at its mgmt IP (e.g. `10.10.10.10`) from the MacBook over the home LAN.
- **You are physically at home** during the install. The bootstrap step
  installs Tailscale on a host that does not yet have a tailnet path. Doing
  this remotely without an out-of-band console is a recipe for locking
  yourself out.
- **No tag scheme yet.** This runbook does not require ACL tags to be
  configured. The device joins under your user identity. Tagging happens
  in Phase 4 (ACL as code).

Decisions baked into this runbook:

- Tailscale runs **directly on the Proxmox host** for now. ADR-0011 calls for
  moving this to a dedicated LXC in Phase 2; Phase 1 is the fastest path to
  remote admin and uses the host install as a stepping stone.
- **Tailscale SSH is enabled.** SSH from the MacBook over the tailnet is
  authenticated by tailnet identity, not by `~/.ssh/authorized_keys`.
- **`--accept-dns=false` on the host.** The host keeps its existing DNS;
  Tailscale only adds the tailnet interface. MagicDNS still works on the
  MacBook side, so `ssh proxmox` resolves there.
- **`--accept-routes=false` on the host.** No subnet routes from other
  tailnet nodes are accepted. The host is a leaf node.

---

## Step 0 — Verify the home-network state before changing anything

From the **MacBook** (at home):

```sh
# Confirm you can reach Proxmox over the LAN.
ping -c 3 10.10.10.10            # adjust to your actual mgmt IP
ssh root@10.10.10.10 'pveversion'

# Confirm you are logged into your tailnet on the MacBook.
tailscale status
```

Expected: `pveversion` returns the Proxmox version string, and
`tailscale status` shows the MacBook with a `100.x.y.z` tailnet IP.

If `tailscale status` says you're logged out, fix that first:
`tailscale up` on the MacBook and reauthenticate before continuing.

---

## Step 1 — Install Tailscale on the Proxmox host

SSH into the host from the MacBook (over LAN):

```sh
ssh root@10.10.10.10
```

On the host, run the official installer:

```sh
# Tailscale's installer detects Debian and configures apt repo + key.
curl -fsSL https://tailscale.com/install.sh | sh

# Sanity check.
tailscale version
systemctl status tailscaled --no-pager
```

Expected: `tailscaled` is `active (running)`. The installer adds a systemd
unit and enables it for boot.

**Why pipe-to-sh from a vendor URL is acceptable here:** the installer is
served over TLS from `tailscale.com`, signed packages come from
`pkgs.tailscale.com`, and the alternative (manual GPG-key + apt-source
setup) is mechanically identical with more steps. If you prefer the manual
route, follow <https://tailscale.com/kb/1031/install-linux> § Debian.

---

## Step 2 — Bring the host onto the tailnet

Still on the Proxmox host:

```sh
tailscale up \
  --ssh \
  --hostname=proxmox \
  --accept-dns=false \
  --accept-routes=false
```

Flag rationale:

| Flag | Purpose |
|---|---|
| `--ssh` | Enables Tailscale SSH on this host. Tailnet-origin SSH connections are authenticated by tailnet identity. |
| `--hostname=proxmox` | The MagicDNS name for this device. Will resolve from the MacBook as `proxmox` (and `proxmox.<tailnet>.ts.net`). |
| `--accept-dns=false` | Do **not** let Tailscale rewrite this host's `/etc/resolv.conf`. Host DNS continues to flow through the network's existing resolver. See ADR-0011 § DNS strategy. |
| `--accept-routes=false` | Do **not** install subnet routes from other tailnet nodes on this host. The host is a leaf, not a transit node. |

Tailscale will print an authentication URL:

```
To authenticate, visit:
  https://login.tailscale.com/a/xxxxxxxxxxxx
```

Open that URL in the **MacBook** browser, log in with the same identity that
owns your tailnet, and approve the device. The `tailscale up` command on the
host will return once authentication completes.

---

## Step 3 — Confirm the host has a tailnet identity

On the Proxmox host:

```sh
tailscale status
tailscale ip -4
```

Expected:

- `tailscale status` shows the host as itself with a `100.x.y.z` IP and
  shows the MacBook as a peer.
- `tailscale ip -4` prints the host's tailnet IPv4 address.

Note this address. It's the `100.x.y.z` you'll fall back to if MagicDNS
ever has issues.

---

## Step 4 — Verify reachability from the MacBook (still at home)

On the **MacBook**:

```sh
# DERP-aware ping. Confirms the overlay is functional.
tailscale ping proxmox

# Direct SSH over Tailscale SSH — no key needed.
ssh root@proxmox

# Web UI.
open https://proxmox:8006
```

Expected:

- `tailscale ping` reports a direct connection within a few packets, or a
  DERP-relayed connection if direct doesn't establish (also fine for now).
- SSH connects without prompting for a password or key. The first time
  you'll get a host-key prompt — accept it.
- The browser shows the Proxmox UI with a self-signed cert warning. That's
  expected; certificate work is a later phase.

If SSH fails with "Permission denied (tailscale)", check that the default
ACL on a new tailnet allows `tag:` and user-to-user reach. On a freshly
created tailnet, the default policy permits the owner-user to reach all
their own devices, which is what you want for Phase 1.

---

## Step 5 — Confirm reachability from *outside* the home network

This is the actual test of the whole exercise. Take the MacBook off home
Wi-Fi: tether to your phone's hotspot, or step out to a coffee shop.

```sh
# Verify the MacBook still sees the tailnet.
tailscale status

# Re-run the same checks.
ssh root@proxmox 'pveversion'
open https://proxmox:8006
```

Expected: identical results to Step 4.

If `ssh proxmox` hangs:

- `tailscale ping proxmox` — does the overlay see the host?
- On the host (via the local console if you have it, or wait until back on
  LAN): `systemctl status tailscaled` and `journalctl -u tailscaled -n 50`.
- Check the Tailscale admin console: is the `proxmox` device "Connected"?
  If the device is showing a stale status, the home internet may have
  dropped at some point and the host needs `tailscale up` to re-register.

---

## Step 6 — Post-bootstrap hardening

Three small changes to make the install stable:

### 6.1 — Disable key expiry on the host

By default, Tailscale device keys expire after 180 days, which would
silently log out the Proxmox host and lock you out remotely. Lab
infrastructure runs unattended; key expiry on `tag:lab-host` devices is
explicitly turned off in ADR-0011.

In the Tailscale admin console:

1. Open <https://login.tailscale.com/admin/machines>.
2. Find the `proxmox` device.
3. Open the device's "..." menu → **Disable key expiry**.

### 6.2 — Confirm Tailscale SSH is recorded in the admin console

Same admin console, device detail page → **SSH** tab. You should see the
device listed as accepting Tailscale SSH connections. If not, on the host:

```sh
tailscale set --ssh=true
```

### 6.3 — Leave the host's regular sshd alone

The host's normal `sshd` continues to listen on the LAN interface. That's
fine — the LAN path is gated by ADR-0004's mgmt VLAN firewall rules. Do
**not** disable LAN-side sshd: it's your fallback if Tailscale ever has a
problem and you're at home.

If at some later point you want to lock LAN-side sshd to key-only (no
passwords), that's worth doing — but it's independent of Tailscale and
belongs in a host-hardening runbook, not this one.

---

## Step 7 — What's deliberately not done in Phase 1

These items are tracked for later phases. Do **not** be tempted to do them
now; doing them out-of-order causes ACL drift that's painful to untangle.

- **No tagging of the device.** It currently joins as a user-owned device.
  Tag assignment requires the ACL policy to declare tag owners; that's
  Phase 4.
- **No subnet routing.** The host is a tailnet leaf, not a router for the
  mgmt VLAN. Reaching `10.10.10.x` hosts other than `proxmox` itself still
  requires being on the home LAN. Phase 2 fixes this.
- **No exit-node advertisement.** The Proxmox host is not your personal-use
  exit node — separate device, Phase 3.
- **No Tailscale Funnel** (publicly-reachable services via Tailscale's edge).
  ADR-0011 disallows it; public service traffic uses Cloudflare Tunnel.
- **No `tailscale cert`** for a real TLS cert on the Proxmox UI yet. The
  self-signed cert is acceptable for Phase 1; cert provisioning is part of
  the Phase 2 LXC runbook where it can be done once and reused.

---

## Rollback

If you decide Tailscale on the host was the wrong call (e.g. you want to
move straight to the LXC subnet router pattern):

```sh
# On the Proxmox host:
tailscale logout
tailscale down
systemctl disable --now tailscaled
apt remove --purge tailscale
```

In the admin console, delete the `proxmox` device. The repo ADR-0011
remains accurate; only the runbook artifact needs to be marked as "skipped".

---

## Verification checklist

- [ ] `tailscale status` on the Proxmox host shows the host and the MacBook.
- [ ] `tailscale ping proxmox` from the MacBook returns within a few packets.
- [ ] `ssh root@proxmox` from the MacBook works without a key.
- [ ] `https://proxmox:8006` loads the Proxmox UI from the MacBook.
- [ ] All four checks above also work from a non-home network.
- [ ] Key expiry disabled on the `proxmox` device in the admin console.

When all six are checked, Phase 1 is complete. Move on to ADR-0011's
Phase 2 (LXC subnet router) when you're ready to extend reach to the rest
of the mgmt VLAN.
