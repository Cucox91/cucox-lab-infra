# Runbook 00a — Hardware: Relocate 1 TB NVMe (Pi5 → Ryzen) and create `tank` pool

> **Goal:** Physically move the 1 TB NVMe from the 16 GB Raspberry Pi 5 into
> a second M.2 slot on the Ryzen workstation, then create the second ZFS
> pool (`tank`) per `ARCHITECTURE.md` § 4.2.
>
> **When to run:** Before runbook `00-phase0-proxmox-bootstrap.md` if you
> can — it's cleanest to install Proxmox with both disks already present.
> Can also be run after Proxmox is already installed (with a brief shutdown).
>
> **Estimated time:** 45–75 minutes including disassembly, install, BIOS
> verification, and pool creation. ESD-cautious work, no rush.
>
> **Risk level:** Medium. You're handling exposed PCBs and an SSD that
> currently has a filesystem on it. If you skip the data-preservation step
> you lose whatever was on the Pi5's NVMe.

---

## Prerequisites

- 16 GB Raspberry Pi 5 with the 1 TB NVMe on a HAT (you're harvesting the
  NVMe).
- Ryzen workstation, powered down, accessible (not in a tight cabinet).
- Phillips #1 and #0 screwdrivers.
- An anti-static wrist strap (preferred) or a known-good way to discharge
  yourself before handling components (touch a grounded metal surface like
  a radiator or the bare metal of the unplugged PSU chassis).
- Plastic anti-static bag or the original NVMe packaging to hold the SSD
  while it's out.
- A USB drive or external disk (≥ 32 GB) for backing up anything currently
  on the Pi5's NVMe — *only* if you have data on it you care about.
- The Ryzen motherboard manual handy (as a PDF on the Mac Air or printed).
  You need it to find the second M.2 slot and confirm which generation it
  is. Search for the board name on the manufacturer's site if you don't
  have the manual.

---

## Step 0 — Decide what the Pi5 boots from afterwards

The Pi5 is parked until Phase 5, so this isn't urgent — but it's worth
deciding now so you don't end up scavenging parts in six months.

Three options, in increasing order of cost and performance:

| Option | Cost | Notes |
|---|---|---|
| **microSD card** | $10–$20 | Slowest. Fine for a parked Pi or light testing. Use A2-rated cards (SanDisk Extreme, Samsung Pro Endurance) if you go this route. |
| **USB 3 SSD** | $25–$50 | Faster than SD, no HAT changes needed. Boots fine on Pi5. Cable management is ugly. |
| **Smaller NVMe** (256 GB) | $25–$30 | Same HAT, same form factor as what you removed. Cleanest end state. Recommended if you'll definitely use the Pi in Phase 5. |

You don't have to decide right now — once the NVMe is out, the Pi5 is just
parked hardware. Make this call before Phase 5 starts.

---

## Step 1 — Backup anything important on the Pi5's NVMe

If the Pi5 was actively running services (Pi-Hole, Home Assistant, a media
server, anything else you care about), back up the data **before** powering
down. Easiest path:

```sh
ssh pi@<pi5-ip>
sudo rsync -av --progress /home/ /opt/ /etc/ <username>@<another-host>:/backup/pi5/
```

If the Pi was only running a clean OS with no real workloads, skip this —
the NVMe will be wiped when it joins the Ryzen as the `tank` pool, and any
existing filesystem is destroyed.

If you want a full image of the NVMe before wiping:

```sh
# From another Linux/Mac box, with the NVMe attached via USB enclosure:
sudo dd if=/dev/sdX of=~/pi5-nvme-image.img bs=4M status=progress
# Compress: gzip -9 < ~/pi5-nvme-image.img > ~/pi5-nvme-image.img.gz
```

(That step is optional and slow. Skip unless you want a recoverable
snapshot.)

---

## Step 2 — Power down the Pi5 cleanly

```sh
ssh pi@<pi5-ip> sudo shutdown -h now
```

Wait until the green ACT LED stops blinking and goes solid off. Then unplug
the USB-C power and disconnect any HDMI, USB, and Ethernet cables.

> Yanking the power on a running Pi5 with an NVMe risks corrupting the
> filesystem you might still want to read later. Always shut down first.

---

## Step 3 — Remove the NVMe HAT and the SSD from the Pi5

Specifics vary by HAT vendor (official Raspberry Pi M.2 HAT+, Pimoroni
NVMe Base, Pineboards HatDrive!, 52Pi NVMe Base, Geekworm X1001/X1002).
The general procedure:

1. **Discharge yourself** by touching a grounded metal surface (radiator,
   case of an unplugged PC).
2. Unscrew the four standoff/screws holding the HAT to the Pi5. Note where
   they came from — usually two on the GPIO side, two on the opposite side.
3. Lift the HAT straight up. The **PCIe FFC ribbon cable** between the
   Pi5 and the HAT will either lift with the HAT (still connected at one
   end) or unseat. Don't stress this cable — it's fragile.
4. With the HAT separated from the Pi5, locate the M.2 SSD on the HAT.
   It's held by a single small screw at the far end (opposite the M.2
   connector). Unscrew it.
5. The NVMe will spring up at a slight angle. Pull it straight out of the
   M.2 connector — gentle, even pressure, no twisting.
6. Note the form factor printed on the SSD (commonly **2280** = 22 mm
   wide, 80 mm long; could be 2230 or 2242 for shorter drives). Note the
   model number too (printed on the label) for your records.
7. Place the NVMe in an anti-static bag or in the slot on the side of the
   replacement NVMe's packaging.

**Reassembly note for later:** keep the HAT and the screw with the Pi5 so
when you replace the boot device you can drop a new SSD in without
hunting for parts.

---

## Step 4 — Confirm the Ryzen has a free M.2 slot

Look up your motherboard model:

```sh
# If the Ryzen has any OS booted, run:
sudo dmidecode -s baseboard-product-name
sudo dmidecode -s baseboard-manufacturer
```

Otherwise, look on the board itself — the model is silkscreened near the
24-pin power connector or between the PCIe slots.

In the manual, find the **M.2 slot table**. You're looking for:

- How many M.2 slots are present (typically 2 on AM4 X570/B550 boards,
  sometimes 3 on premium boards).
- Which slot is **PCIe Gen 4 x4 (CPU-attached)** — the fastest. If your
  primary NVMe (the one Proxmox will install on) is already in this slot,
  use a Gen 3 slot for the second NVMe; the speed difference (~7 GB/s
  vs ~3.5 GB/s) is irrelevant for a `tank` pool serving VM zvols.
- Which slot is **chipset-attached (Gen 3 or Gen 4 via the chipset PCH)** —
  this is fine for the second drive.
- **What devices the slot shares bandwidth with.** Some M.2 slots are
  multiplexed with SATA ports — if the slot you want is shared with
  SATA 5/6 and you have SATA drives in those ports, you'll lose them.
  Confirm you don't care about that.

If the board has only one M.2 slot or both are occupied: an
**M.2-to-PCIe x4 adapter card** (~$15) lets you plug the NVMe into any
free PCIe x4+ slot. This works fine for `tank` performance.

---

## Step 5 — Install the NVMe in the Ryzen

1. **Power down the Ryzen** if it's running. Unplug the power cable from
   the wall (not just the back of the PSU). Hold the case power button
   for 5 seconds to discharge any residual current from the PSU caps.
2. Open the case side panel.
3. Discharge yourself again on the case's bare metal frame.
4. Locate the chosen M.2 slot. It usually has a heatsink covering it
   (one or two small Phillips screws). Remove the heatsink and set it
   aside.
5. The slot has a **standoff screw** at the far end matching the SSD's
   form factor (commonly 2280). If the standoff is at the wrong position
   for your SSD's length, move it: it usually unscrews and screws into a
   different threaded hole. Do not force it.
6. Insert the NVMe into the M.2 connector at a ~30° angle, fully seated
   (no gold contacts visible).
7. Press the SSD down flat against the standoff and screw in the
   retention screw — gentle, just snug. Overtightening can crack the PCB.
8. **Replace the M.2 heatsink** (with its thermal pad making contact with
   the SSD). Heat is the #1 cause of NVMe slowdowns under sustained load,
   which absolutely matters when you start running benchmarks.
9. Close the case. Reconnect power and peripherals. Don't power on yet.

---

## Step 6 — Verify the disk in BIOS

1. Power on the Ryzen and immediately tap **Del** (or **F2** depending on
   board) to enter BIOS/UEFI.
2. Find the storage / SATA / NVMe configuration screen. The exact name
   varies (ASUS: "Advanced → Onboard Devices → M.2 Configuration",
   MSI: "Settings → Advanced → Storage Configuration", etc.).
3. Confirm **both NVMes are listed** by model and capacity.
4. If only one shows up: power off, re-seat the new NVMe, and check the
   manual for whether the slot you used requires explicit enabling in
   BIOS (rare on AM4, more common on AM5).
5. Save and exit BIOS (no other changes needed if you already did the
   BIOS prep in Phase 0 step 5.3).

---

## Step 7 — Decide: install Proxmox now, or you've already installed it?

Two paths from here:

**Path A — Proxmox is not yet installed (recommended).** You're following
the Phase 0 runbook from scratch with both disks present. Continue with
runbook `00-phase0-proxmox-bootstrap.md` from Step 5.4. **At the disk
selection screen, choose only the original 1 TB NVMe as the ZFS install
target.** Proxmox will create `rpool` on that drive only, leaving the
relocated NVMe untouched and ready for `tank`. After Step 8 of the Phase 0
runbook, return here and continue at Step 8 below.

**Path B — Proxmox is already installed on `rpool`.** The new NVMe is
sitting in the chassis but Proxmox doesn't know about it yet. SSH in and
continue at Step 8 below directly.

---

## Step 8 — Identify the new disk in Linux

SSH to the Proxmox host:

```sh
ssh root@10.10.10.10
```

List block devices:

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINT
```

Expected output: two NVMes (`nvme0n1` and `nvme1n1`), plus the partitions
on whichever one Proxmox installed to. Identify the new (clean) drive by
size and model — the one with **no partitions** is the relocated SSD.

Get the stable `/dev/disk/by-id/` path (always use this with ZFS — never
the `/dev/nvmeXn1` name, which can renumber across reboots):

```sh
ls -l /dev/disk/by-id/ | grep nvme
```

You'll see entries like:

```
nvme-Samsung_SSD_980_PRO_1TB_S1234567       -> ../../nvme0n1
nvme-WDC_WDS100T3X0E_2024XX0123XX           -> ../../nvme1n1
```

The one pointing at the new drive (no partitions in `lsblk`) is your
target. Save it as a variable so you don't typo:

```sh
NEW_DISK="/dev/disk/by-id/nvme-WDC_WDS100T3X0E_2024XX0123XX"
ls -l "$NEW_DISK"        # confirm the symlink resolves
```

---

## Step 9 — Wipe any leftover data on the relocated disk

The disk has a Pi OS filesystem on it. Destroy it before handing the
whole device to ZFS:

```sh
# This erases all partition tables and filesystem signatures.
# The disk's data becomes immediately unreadable. Be certain.
wipefs -a "$NEW_DISK"

# Belt and suspenders — also clear any GPT/MBR labels:
sgdisk --zap-all "$NEW_DISK"

# Confirm it's clean now:
lsblk "$NEW_DISK"
# Expect: just the disk, no child partitions.
```

---

## Step 10 — Create the `tank` pool

Single-device ZFS pool, ashift=12 (correct for any modern NVMe with 4K
physical sectors):

```sh
zpool create \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O mountpoint=/tank \
  tank "$NEW_DISK"
```

Verify:

```sh
zpool status tank
# Expect: state ONLINE, no errors, single disk by-id name shown.

zpool list tank
# Expect: ~930G capacity (1TB drives are ~931 GiB).

zfs list tank
# Expect: tank with mountpoint /tank.
```

---

## Step 11 — Create the datasets per § 4.2

```sh
# Primary VM working area (zvols land here by default).
zfs create -o recordsize=16K tank/vmdata

# Benchmark scratch — bigger recordsize, can be wiped freely.
zfs create -o recordsize=128K tank/bench

# Verify.
zfs list -r tank
# Expect:
#   tank
#   tank/bench
#   tank/vmdata
```

---

## Step 12 — Register `tank` as Proxmox storage

This is the step that makes the new pool *visible* to Proxmox so the UI,
Terraform, and `qm` commands can use it.

```sh
# Add tank/vmdata as a ZFS-backed VM storage (zvol-backed disks):
pvesm add zfspool tank-vmdata \
  --pool tank/vmdata \
  --content images,rootdir \
  --sparse 1

# Add tank/bench as a directory-backed storage for arbitrary files
# (benchmark traces, replay logs, etc.):
mkdir -p /tank/bench
pvesm add dir tank-bench \
  --path /tank/bench \
  --content snippets,iso,backup
```

Verify:

```sh
pvesm status
```

Expected output includes both `tank-vmdata` (ZFS pool) and `tank-bench`
(directory) as available storages, both `active`.

---

## Step 13 — Make `tank-vmdata` the default for new VM disks

Otherwise Terraform will keep dropping new VM zvols on `local-zfs`
(`rpool/data`). You can either:

**(a)** Change the order in the Proxmox web UI:
*Datacenter → Storage → tank-vmdata → Edit → ensure "Enabled" and not
restricted to specific nodes.*

**(b)** Pin it in the Terraform module — set the storage ID explicitly
in `terraform/proxmox/modules/vm/main.tf`:

```hcl
resource "proxmox_vm_qemu" "this" {
  # ...
  disk {
    storage = "tank-vmdata"
    type    = "scsi"
    size    = "${var.disk_size_gb}G"
    # ...
  }
}
```

The Terraform path is the right answer (explicit > implicit, and IaC
should not depend on UI-set defaults).

---

## Step 14 — Verify and quick benchmark

Confirm health:

```sh
zpool status tank
zfs get compression,atime,recordsize tank tank/vmdata tank/bench
```

Quick sequential write test (NOT a real benchmark — just a sanity check
that the disk is hooked up correctly):

```sh
# Write 4 GiB of zeros directly to a file, sync after.
dd if=/dev/zero of=/tank/bench/sanity.bin bs=1M count=4096 oflag=direct,sync
# Expect: ~2-5 GB/s on a Gen 4 NVMe through ZFS with lz4 compression.
# (Compression makes /dev/zero unrealistically fast — this is just
# checking the device works, not measuring real performance.)
rm /tank/bench/sanity.bin
```

Proxmox's bundled fsync-IOPS test:

```sh
pveperf /tank/bench
# Look for FSYNCS/SECOND > 5000 (NVMe should easily clear this).
```

ZFS health check:

```sh
zpool scrub tank
# Background, takes seconds-to-minutes for a fresh empty pool.
zpool status tank
# Wait for "scan: scrub repaired 0B" with no errors.
```

---

## Step 15 — ARC re-cap (only if you skipped this in Phase 0)

If you're running this runbook *after* Phase 0 was already complete and
you didn't set the ARC limit, do it now — adding a second pool roughly
doubles ZFS's appetite for cache memory:

```sh
# Cap ARC at 16 GB (out of 64 GB host RAM).
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/zfs.conf
update-initramfs -u -k all

# Verify after reboot:
reboot
# When back: cat /sys/module/zfs/parameters/zfs_arc_max
# Expect: 17179869184
```

---

## Step 16 — Commit the change

In the repo:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"

# Capture the actual disk-by-id you used in your inventory file
# (will be referenced by Ansible / Terraform later).
echo "tank_disk_byid: ${NEW_DISK}" >> ansible/inventory/host_vars/lab-prox01.yml
git add .
git commit -m "feat(storage): add tank pool on relocated NVMe"
```

Update `docs/decisions/0009-two-pool-storage.md` (the ADR for the
two-pool decision) with the actual SSD model and serial — useful when
the disk eventually fails and you're reading shipping invoices to
identify what to reorder.

---

## What's done

- 1 TB NVMe physically moved from Pi5 (16 GB) to a second M.2 slot in the
  Ryzen workstation.
- Pi5 parked, ready for a microSD or replacement NVMe before Phase 5.
- `tank` ZFS pool created on the new drive, with `tank/vmdata` (16K
  recordsize) and `tank/bench` (128K recordsize) datasets.
- Proxmox storages registered: `tank-vmdata` (zvols) and `tank-bench`
  (directory).
- Default VM storage path documented for Terraform.
- ARC capped at 16 GB system-wide.

## What's next

- If you ran Path A (pre-install): continue with the rest of
  `00-phase0-proxmox-bootstrap.md` from Step 9 (verification).
- If you ran Path B (post-install): you're done with the hardware track;
  proceed to runbook `01-phase1-vm-bringup.md` whenever it's written.

## Rollback

The `tank` pool can be destroyed cleanly without affecting `rpool` or
the Proxmox install:

```sh
# Make sure no VMs have disks on tank-vmdata first.
pvesm remove tank-vmdata
pvesm remove tank-bench
zpool destroy tank
wipefs -a "$NEW_DISK"
```

The relocated NVMe can then be physically returned to the Pi5 and
re-imaged with Raspberry Pi OS via `rpi-imager`. The Pi will have lost
whatever was on the drive — the rsync backup from Step 1 is the only way
back to its prior state.
