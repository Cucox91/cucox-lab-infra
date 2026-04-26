# ADR-0011 — Phase 1 single-pool ZFS deviation from ADR-0009

| | |
|---|---|
| **Status** | Active (deviation, time-boxed) |
| **Date** | 2026-04-26 |
| **Deciders** | Raziel |
| **Supersedes** | — |
| **Modifies** | [ADR-0009](../../ARCHITECTURE.md#12-decision-log) (target end-state, not retracted) |

## Context

[ADR-0009](../../ARCHITECTURE.md#12-decision-log) committed the lab to a two-pool
ZFS storage layout (`rpool` for system + ISOs + templates, `tank` for VM
data + benchmark scratch), backed by two separate NVMe drives. The second
NVMe was to be relocated from the Pi5 (where its Gen 4 speed is wasted on
a Gen 2 x1 HAT).

As of 2026-04-26, the second NVMe has **not been physically relocated**.
The Ryzen workstation has only the original 1 TB NVMe installed. We need
to start Phase 1 (VM template + cluster bringup) before the relocation
happens, so that runbook progress isn't blocked on a hardware step that
can be deferred without harm.

## Decision

For Phase 1 only, **VMs run on `rpool/data` (Proxmox storage `local-zfs`,
created automatically by the installer)**. The `tank` pool is not created.
ADR-0009's two-pool target is **not retracted** — it is deferred. ADR-0011
exists to capture exactly what is being given up in the meantime and how
to close the gap.

Concretely:

- All VM disks (template, six Phase 1 VMs) live on `rpool/data`.
- All ZFS-pool snapshots reference `rpool/data@<name>` only.
- Terraform's `disk.storage` is `"local-zfs"` (with a comment pointing here).
- `runbook 00a` Steps 8–13 (the `tank` pool creation + Proxmox storage
  registration) are still the canonical procedure; they're just paused.

## Trade-offs accepted

This is a deliberate trade. Read each item — these are real costs.

### 1. No fault isolation

A single NVMe failure now wipes Proxmox + every VM disk simultaneously.
Under ADR-0009 the same failure would lose only one of the two pools.
Mitigation:

- ZFS snapshots on `rpool/data` (per-VM via `qm snapshot` and pool-level
  via `zfs snapshot rpool/data@phase1-*`). Snapshots survive a software
  mistake but **not a drive failure**.
- Off-host backups (NAS or external object store) are not yet wired up.
  This is a Phase 4 concern, but during the deviation it's worth
  acknowledging that "lab dies on a single drive failure" is the actual
  posture.

### 2. No I/O isolation

Hypervisor I/O, VM-disk I/O, and any benchmark I/O share the same NVMe
queue. For idle / low-traffic Phase 1 workloads this is fine; for any
performance measurement (Phase 5 broker work) it is **disqualifying**. We
will not run benchmarks during the deviation period and call them valid.
ADR-0009's I/O-isolation rationale is preserved precisely because we
won't pretend it doesn't exist.

### 3. No `tank/bench` dataset

Benchmark scratch (`tank/bench` with `recordsize=128K`, free to wipe) is
unavailable. Not a Phase 1–4 blocker; matters only when Phase 5 broker
benchmarking begins. If a benchmark is needed sooner, it must wait for
the migration.

### 4. ARC budget

ARC is still capped at 16 GB system-wide (Phase 0 step 8). With only one
pool, that 16 GB serves both system reads (templates, ISOs) and VM-disk
reads. Acceptable on 64 GB total; revisit only if `arc_summary` shows
sustained pressure.

### 5. Capacity headroom

The 1 TB NVMe holds: Proxmox install (~5 GB), `rpool/iso` (~2 GB), the
template (~3.5 GB image, grown to 20 GB on first boot), and six VMs
(40 + 40 + 40 + 80 + 80 + 20 = 300 GB). Total ~330 GB. Comfortable on a
1 TB drive; capacity is not the constraint, fault/I/O isolation is.

## Migration to `tank` (closing the deviation)

Trigger: the second NVMe is physically installed in the Ryzen and the
relocation procedure in [`runbook 00a`](../runbooks/00a-hardware-nvme-relocation.md)
Steps 8–13 has been completed. After that:

1. **Verify** `tank-vmdata` is registered:
   ```sh
   pvesm status | grep -E 'local-zfs|tank-vmdata'   # both `active`
   ```

2. **Migrate the template** (VMID 9000) — must be un-templated first:
   ```sh
   qm set 9000 --template 0
   zfs snapshot rpool/data/vm-9000-disk-0@migrate
   zfs send rpool/data/vm-9000-disk-0@migrate \
     | zfs receive tank/vmdata/vm-9000-disk-0
   qm set 9000 --scsi0 tank-vmdata:vm-9000-disk-0,discard=on,iothread=1,ssd=1
   qm set 9000 --ide2 tank-vmdata:cloudinit
   qm set 9000 --efidisk0 tank-vmdata:0,format=raw,efitype=4m,pre-enrolled-keys=0
   qm template 9000
   ```

3. **Migrate each VM** (full clones from the template, so they have their
   own zvols). Per VM, while stopped:
   ```sh
   qm stop <vmid>
   zfs snapshot rpool/data/vm-<vmid>-disk-0@migrate
   zfs send rpool/data/vm-<vmid>-disk-0@migrate \
     | zfs receive tank/vmdata/vm-<vmid>-disk-0
   qm set <vmid> --scsi0 tank-vmdata:vm-<vmid>-disk-0,discard=on,iothread=1,ssd=1
   qm set <vmid> --ide2 tank-vmdata:cloudinit
   qm start <vmid>
   ```

4. **Update Terraform**: change `terraform/proxmox/main.tf` so
   `disk.storage = "tank-vmdata"`. Run:
   ```sh
   terraform plan
   ```
   Expect drift on the disk attribute. Two acceptable resolutions:
   - `terraform apply -refresh-only` to absorb the post-migration state
     without recreating disks (preferred — non-destructive).
   - `terraform state rm proxmox_vm_qemu.vm[\"<key>\"]` per resource and
     re-import — more surgical, more error-prone.

5. **Verify** with `qm config <vmid> | grep -E 'scsi0|ide2'` that all
   disks reference `tank-vmdata`. Then on `rpool/data`:
   ```sh
   zfs list -r rpool/data    # should show no `vm-*` zvols
   ```

6. **Set Proxmox default storage** to `tank-vmdata` (UI → Datacenter →
   Storage → tank-vmdata → Edit → "Content: Disk image, Container").
   ADR-0009 § "tank as default" is now back in force.

7. **Close this ADR** by setting status to `Superseded by completion`
   in this header table and adding a row to the ARCHITECTURE.md decision
   log noting the migration date. ADR-0009 returns to its un-deviated
   state.

The migration is a teaching artifact in itself — a real `zfs send | receive`
across pools is one of the more practically useful ZFS operations to have
done at least once.

## Risks during the deviation period

- **Drive failure** is the catastrophic case. Snapshots ≠ backups.
  Mitigation: don't put production-critical workloads on the cluster
  until either (a) the migration is done **and** Longhorn is in (Phase 4),
  or (b) off-host backup is operational. Phase 1–2 is hello-world
  workloads only.
- **Forgetting** the deviation exists. Mitigation: this ADR is referenced
  from runbook 01 prerequisites, ADR-0009's status block, and the
  Terraform comment on `disk.storage`. Three breadcrumbs is enough.
- **Performance measurements drawn during deviation** would be invalid.
  Mitigation: Phase 5 (benchmarking) is gated behind ADR-0011 closure.

## Why not other options

### Wait for the NVMe before starting Phase 1

Cleanest from an architecture-fidelity standpoint. Rejected because the
lab's primary value is forward motion + learning, and Phase 1 (template
build, Terraform-driven cloning, k3s HA, Cilium, MetalLB) has nothing to
do with two-pool storage. Blocking learning on a screwdriver step is the
wrong trade.

### Partition the single NVMe into two ZFS vdevs

Would technically give you "two pools." Rejected: gives you the management
complexity of two pools with none of the I/O or fault-tolerance benefit,
plus loses ZFS's whole-disk optimizations (TRIM coordination, write
batching). Strict downgrade from the present plan.

### Buy a second NVMe instead of relocating from the Pi5

Out of scope for this ADR — it's a hardware-procurement decision, not an
architecture decision. ADR-0009 explicitly chose relocation because the
NVMe was wasted on the Pi5's Gen 2 x1 HAT.

## References

- ADR-0009 (decision-log row in ARCHITECTURE.md § 12) — the original
  two-pool decision this ADR temporarily defers. ADR-0009 has not yet
  been promoted to a standalone file under `docs/decisions/`; if/when it
  is, update this reference.
- `docs/runbooks/00a-hardware-nvme-relocation.md` — the procedure that
  closes this deviation.
- `docs/runbooks/01-phase1-vm-bringup.md` — the runbook that consumes
  this deviation; references this ADR in its prerequisites and Terraform
  config comments.
- ARCHITECTURE.md § 4.2 (storage layout target state).
