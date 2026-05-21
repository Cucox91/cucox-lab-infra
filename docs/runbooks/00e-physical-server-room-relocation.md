# 00e — Physical Server Room Relocation

**Scope:** Move the single Proxmox VE host a short distance (e.g. to another room) with
the **same network** — same uplink cable extended, same VLANs, same IPs. All infra VMs
and the 5-node k3s cluster (3 control-plane + 2 workers) run as guests on this one host
with local disks.

**Goal:** Power down, move, power back up with zero data or configuration loss.

**Created:** 2026-05-21

---

## Why this is low-risk

Everything lives on local disks inside one chassis, and the network is unchanged. The
data and config physically travel with the box — a clean power-off loses nothing, and
nothing reconfigures on the other end. With the network constant, only two things
actually matter:

1. **A graceful shutdown** — so no filesystem, VM disk, or k3s etcd is left inconsistent.
2. **Not shocking a drive** in transit — spun-down disks are resilient, but not immune.

The `vzdump` backup in Phase 1 is the insurance: if a drive fails on the move, restore
instead of rebuild.

---

## Phase 1 — Before shutdown

- `cd cucox-lab-infra && git status` → working tree clean. `git push` so the remote has
  the latest Terraform / Ansible / SOPS state.
- Confirm the **age private key** for SOPS exists off-box (password manager / MacBook Air).
- Take a `vzdump` backup of the VMs to an **external disk** — prioritise the 3 k3s
  control-plane nodes and any stateful VM. A backup that rides in the same box protects
  nothing.
- Note each VM's **Start/Shutdown order** and boot delay (Proxmox → VM → Options). If not
  configured, write down the intended order from Phase 4.

---

## Phase 2 — Graceful shutdown (inside-out)

1. *(Optional, tidy)* Cordon/drain the k3s workers:
   ```bash
   kubectl cordon <worker-1> <worker-2>
   kubectl drain <worker-1> --ignore-daemonsets --delete-emptydir-data --grace-period=60
   kubectl drain <worker-2> --ignore-daemonsets --delete-emptydir-data --grace-period=60
   ```
2. Gracefully shut down the guest VMs with **Shutdown** (ACPI) — *never* "Stop" — in
   order: k3s workers → 3 control-plane nodes → infra VMs (cloudflared tunnel, etc.).
   CLI: `qm shutdown <vmid>`. Wait until every guest shows **stopped**; give a slow guest
   a couple of minutes rather than forcing it.
3. Shut down the host: `shutdown -h now`. Wait for fans and the power LED to go out.
4. Switch off the PSU, unplug from the wall, unplug the network cable.

---

## Phase 3 — The move

- Box is powered down and drives are parked — the safe state to move in.
- Carry it **level**, two hands or a cart, avoid sharp knocks. Don't drag it by cables or
  the bezel.
- Set it down gently. If it crossed a big temperature change, let it sit a few minutes
  before powering on (avoid condensation on a cold box).
- Reconnect power (PSU switch still off) and the same network cable.

---

## Phase 4 — Power on and verify (outside-in)

1. Switch on the PSU, power on, watch it POST. SSH to the host's management IP.
2. **Check storage before starting any VM:**
   - ZFS: `zpool status` → pool `ONLINE`, no errors, no `DEGRADED`/`FAULTED` device.
   - `pvesm status` → storage backends active.
   - If a disk shows errors, stop and resolve it — that's what the Phase 1 backup is for.
3. Start the VMs in order (let them auto-start if start order is configured, else
   `qm start <vmid>`):
   - Infra VMs (cloudflared tunnel, etc.)
   - All **3 k3s control-plane** nodes — start them together; etcd needs quorum, so two
     or fewer leaves the API server down.
   - Both **k3s workers**.
4. Verify k3s:
   ```bash
   kubectl get nodes      # all 5 Ready
   kubectl get pods -A    # workloads Running, none stuck Pending/CrashLoop
   ```
   If you cordoned in Phase 2: `kubectl uncordon <worker-1> <worker-2>`.
5. Confirm the cloudflared tunnel reconnected (Cloudflare dashboard) and a service on
   `cucox.me` loads.
6. `zpool status` once more under load; spot-check one stateful workload's data.

---

## Quick reference

| Step      | Direction    | Sequence |
|-----------|--------------|----------|
| Shutdown  | inside → out | workloads → workers → control-plane → infra VMs → host → power |
| Startup   | outside → in | power → host → storage check → infra VMs → control-plane → workers → verify |

## If something doesn't come back

- **k3s API down / nodes NotReady:** confirm all 3 control-plane VMs are running — etcd
  needs quorum.
- **A VM won't boot / storage degraded:** restore that VM from the Phase 1 `vzdump`.
- **SOPS secrets won't decrypt:** confirm the age key matches the one used to encrypt.

> Network note: this runbook assumes the network is unchanged. If the uplink ever moves
> to a different switch port or drop, also verify it carries the same VLAN trunk before
> powering on — see `00a-hardware-nvme-relocation.md` for the network-change variant.
