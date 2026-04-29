# Runbook 00b — Proxmox Baseline Snapshot ("Time Capsule")

> **Goal:** Capture a complete, recoverable checkpoint of the Proxmox host
> immediately after Phase 0 / 00a finish — *before* any VMs, templates,
> Terraform runs, or workloads exist. Future you, after a misconfigured
> kernel module / a bad apt upgrade / a `zpool destroy` typo / a dead
> NVMe, will pay any price for this. Take it now while it's free.
>
> **Estimated time:** 45–75 minutes total. ~2 minutes of attention,
> the rest is `zstd` + `dd` running.
>
> **When to run:** Right after `00-phase0-proxmox-bootstrap.md` Step 9
> (lab-isolation verification passes) and, if applicable,
> `00a-hardware-nvme-relocation.md` Step 14 (`tank` benchmark passes).
> Anything you do in Phase 1+ should be reproducible from this baseline.
>
> **Operator:** You, with Claude Code on the Mac Air.

---

## The mental model: four layers, each defending against a different failure

| Layer | Defends against | Recovery time | Stored where |
|---|---|---|---|
| 1. ZFS recursive snapshot (on-pool) | Bad config edit, broken upgrade, "I want yesterday back" | Seconds (`zfs rollback`) | `rpool` itself |
| 2. `zfs send` to off-pool storage | Pool destruction, dataset corruption, accidental `zpool destroy` | 10–30 min (`zfs receive` to fresh pool) | USB SSD / NAS |
| 3. Block-level image of the boot NVMe | Dead disk, brick the bootloader, wrong-rootfs catastrophe | 30 min (Clonezilla restore to new NVMe) | USB SSD / NAS |
| 4. Config tarball | "I just want to grep what `/etc/network/interfaces` looked like" | Seconds (`tar xzf`) | Anywhere — small enough for cloud/git |

In an IaC-driven lab, the host is *mostly* reproducible from runbooks. These
layers protect the *irreducible* state: live filesystem data, host keys,
the bootloader, generated config that didn't come from the runbooks.

---

## What this runbook does NOT capture

These are real failure modes that need separate handling:

- **BIOS / UEFI settings.** SVM, IOMMU, boot order, Above-4G, Resizable BAR.
  Documented in `00-phase0-proxmox-bootstrap.md` Step 5.3 — re-apply by hand
  on a board replacement. Consider taking phone photos of each BIOS screen
  *after* you set them and stashing them next to the image from Layer 3.
- **UniFi configuration.** Networks, VLANs, firewall rules, port profiles,
  Wi-Fi networks. Export from **UniFi → Settings → System → Backups →
  Download Backup**. Treat that file as part of the same baseline; copy
  it next to the Layer 3 image.
- **Age private key** at `~/.config/sops/age/keys.txt` on the Mac Air.
  This is the lab's crown jewel — losing it means every SOPS-encrypted
  secret in this repo is unrecoverable. Back up to a password manager
  (1Password, Bitwarden secure notes) AND a hardware-encrypted USB.
  Do not store it in any of this runbook's outputs.
- **UEFI NVRAM boot entries.** Block-level imaging won't catch these on
  most systems. Recreate with `efibootmgr` post-restore; not worth chasing
  proactively.

---

## Prerequisites

- Phase 0 runbook complete; if applicable, Phase 0a complete.
- A USB SSD or NAS share with at least:
  - **~100 GB free** for Layers 1–4 of a fresh, near-empty install.
    (Will grow once you have VMs; the empty baseline is small.)
  - Filesystem the Proxmox host can write to — `ext4` or `xfs` is simplest;
    `zfs` is fine if you'd rather; **avoid `exfat` and `ntfs`** for
    multi-GB streams.
- A Clonezilla Live USB (separate from the Proxmox installer USB if you
  still have it) — download from <https://clonezilla.org/downloads.php>,
  write to USB the same way you wrote the Proxmox installer in 00 step 5.2.
- Mac Air on `CucoxLab-Mgmt` (VLAN 10) so SSH to `10.10.10.10` works.

---

## Naming convention

Use a consistent naming scheme so you can keep multiple checkpoints over time
without confusing yourself:

```
rpool@phase<N>-<event>-YYYY-MM-DD
tank@phase<N>-<event>-YYYY-MM-DD
```

Examples you'll accumulate over the project:

```
rpool@phase0-clean-2026-04-27          ← this runbook
rpool@phase1-template-built-…
rpool@phase1-vms-up-…
rpool@phase2-k3s-bootstrapped-…
```

Set the variable once and re-use throughout the steps below:

```sh
TAG="phase0-clean-$(date -u +%Y-%m-%d)"
echo "$TAG"
# Expected: phase0-clean-2026-04-27
```

---

## Layer 1 — Recursive ZFS snapshot (on-pool)

Free, instant, reversible in place. Always the first action.

```sh
ssh root@10.10.10.10
TAG="phase0-clean-$(date -u +%Y-%m-%d)"

# Recursive snapshot of root pool — captures rpool, rpool/ROOT,
# rpool/ROOT/pve-1, rpool/data, rpool/iso, rpool/snapshots.
zfs snapshot -r "rpool@${TAG}"

# If 00a was completed and tank exists:
if zpool list tank >/dev/null 2>&1; then
  zfs snapshot -r "tank@${TAG}"
fi

# Verify
zfs list -t snapshot -o name,creation,used,referenced \
  | grep -E "@${TAG}"
```

Expected: one line per dataset (`rpool`, `rpool/ROOT`, `rpool/ROOT/pve-1`,
`rpool/data`, `rpool/iso`, `rpool/snapshots`, plus `tank`, `tank/vmdata`,
`tank/bench` if applicable). `USED` will be `0B` for now — snapshots are
copy-on-write, costing space only as the live filesystem diverges.

**Hold the snapshots so an accidental `zfs destroy -r rpool` won't delete
them silently:**

```sh
zfs hold -r "baseline:${TAG}" "rpool@${TAG}"
[ -n "$(zpool list -H -o name tank 2>/dev/null)" ] && \
  zfs hold -r "baseline:${TAG}" "tank@${TAG}"

# Verify holds:
zfs holds "rpool@${TAG}"
```

---

## Layer 2 — `zfs send` to off-pool storage

Snapshots that live on `rpool` die with `rpool`. Send a replication stream
to external storage so the baseline survives a pool destruction.

### 2.1 Mount the destination

Plug a USB SSD into the Ryzen and mount it. Confirm it's *not* one of the
existing pool members before formatting anything:

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINT
# Identify the new USB SSD by model/serial. It should have no children
# from the rpool/tank pools.

USB_DEV=/dev/disk/by-id/usb-<vendor>_<model>_<serial>-0:0   # adjust to yours

# If it needs formatting (one-time), use ext4 (simple, journaled, big-file friendly):
# parted "$USB_DEV" mklabel gpt mkpart primary ext4 0% 100%
# mkfs.ext4 -L pve-baseline /dev/disk/by-partlabel/primary

mkdir -p /mnt/baseline
mount LABEL=pve-baseline /mnt/baseline    # or the partition path directly
df -h /mnt/baseline
```

(If you'd rather send to a NAS share over NFS or SMB, mount it the same
way and use the mount point in place of `/mnt/baseline` below. Avoid
`exfat`/`ntfs` for multi-GB streams.)

### 2.2 Send the streams

`-R` = replication stream (includes child datasets, properties, holds).
`zstd -T0` uses all cores; on a near-empty baseline this finishes in
single-digit minutes.

```sh
mkdir -p "/mnt/baseline/${TAG}"

zfs send -R "rpool@${TAG}" \
  | zstd -T0 -19 \
  > "/mnt/baseline/${TAG}/rpool-${TAG}.zfs.zst"

if zpool list tank >/dev/null 2>&1; then
  zfs send -R "tank@${TAG}" \
    | zstd -T0 -19 \
    > "/mnt/baseline/${TAG}/tank-${TAG}.zfs.zst"
fi
```

### 2.3 Record stream metadata for restore-time sanity

```sh
{
  echo "# Baseline ${TAG} — captured $(date -u --iso-8601=seconds)"
  echo
  echo "## Host"
  hostnamectl
  echo
  echo "## Pools"
  zpool list -v
  echo
  echo "## Datasets"
  zfs list
  echo
  echo "## Snapshots in this baseline"
  zfs list -t snapshot -o name,creation,used,referenced | grep "@${TAG}"
  echo
  echo "## Stream sizes"
  ls -lh "/mnt/baseline/${TAG}/"
  echo
  echo "## Checksums"
  sha256sum "/mnt/baseline/${TAG}/"*.zfs.zst
} > "/mnt/baseline/${TAG}/MANIFEST.md"

cat "/mnt/baseline/${TAG}/MANIFEST.md"
```

### 2.4 Verify the streams are decodable (paranoid but cheap)

A corrupt stream is worse than no stream — you'll find out at the worst
possible time. Decompress and pipe to `zstreamdump` to validate without
actually receiving:

```sh
zstd -dc "/mnt/baseline/${TAG}/rpool-${TAG}.zfs.zst" \
  | zstreamdump | tail -20
# Expected: a clean END record with no errors.
```

Repeat for the `tank` stream if applicable.

---

## Layer 3 — Block-level image of the boot NVMe (do this once)

This is the closest thing to a "Time Machine" snapshot of the OS itself.
Captures the EFI System Partition, GRUB, and the entire on-disk layout.
Recovers from a dead bootloader or a dead disk.

> Why a separate USB rather than `dd` from the running Proxmox: imaging a
> live filesystem can produce inconsistent images. We boot Clonezilla
> from USB so the source disk is quiescent.

### 3.1 Identify the boot NVMe by-id

Before shutting down, capture the stable identifier:

```sh
ssh root@10.10.10.10
ls -l /dev/disk/by-id/ | grep -E 'nvme.*-part1' | head
# Note the by-id name of the disk that owns the EFI partition (-part1).
# This is your boot NVMe. Write it down.
```

Also note used vs. total disk space — used space is what limits image size:

```sh
zpool list rpool
# CAP column = used %. A fresh install is typically <5%.
```

### 3.2 Boot Clonezilla from USB

1. `shutdown -h now` on the Proxmox host.
2. Plug Clonezilla USB and the Layer-2 baseline USB SSD into the Ryzen.
3. Power on, F11 (or your board's boot menu key) → boot the Clonezilla
   USB.
4. Choose **default settings**, English, then **device-image** mode →
   **local_dev** for source/dest.
5. Source disk: the boot NVMe (verify by size and model — match what you
   noted in 3.1).
6. Destination: the baseline USB SSD, directory
   `/<TAG>/` (Clonezilla will create subfolders inside).
7. Mode: **savedisk** (whole device, all partitions). Compression:
   **zstd**. Check image: **yes**.
8. Let it run (~15–40 min depending on used space and USB speed).
9. When done, **poweroff** from the Clonezilla menu, remove both USBs,
   power on as normal — Proxmox should boot back to its usual state.

### 3.3 Document where the image lives

Append to the manifest from 2.3:

```sh
ssh root@10.10.10.10
mount LABEL=pve-baseline /mnt/baseline
{
  echo
  echo "## Layer 3: Clonezilla image"
  echo "Source disk by-id: <paste from 3.1>"
  echo "Image directory: /mnt/baseline/${TAG}/<clonezilla-folder-name>/"
  ls -lh "/mnt/baseline/${TAG}/" | grep -v MANIFEST
} >> "/mnt/baseline/${TAG}/MANIFEST.md"
```

---

## Layer 4 — Config tarball

Tiny, portable, easy to diff against future state. Useful even if Layers
1–3 are intact, just for "what did `/etc/network/interfaces` look like
before I edited it."

```sh
ssh root@10.10.10.10
mount LABEL=pve-baseline /mnt/baseline 2>/dev/null
TAG="phase0-clean-$(date -u +%Y-%m-%d)"   # re-set if shell is fresh

tar --warning=no-file-changed -czf "/mnt/baseline/${TAG}/pve-config-${TAG}.tgz" \
  /etc/network/interfaces \
  /etc/hosts /etc/hostname /etc/resolv.conf \
  /etc/ssh \
  /etc/pve \
  /var/lib/pve-cluster \
  /etc/apt/sources.list \
  /etc/apt/sources.list.d \
  /etc/modprobe.d \
  /etc/fstab \
  /root/.ssh

ls -lh "/mnt/baseline/${TAG}/pve-config-${TAG}.tgz"
sha256sum "/mnt/baseline/${TAG}/pve-config-${TAG}.tgz" \
  >> "/mnt/baseline/${TAG}/MANIFEST.md"
```

`/etc/pve` is the FUSE-mounted Proxmox cluster config — it's the part of
the install that distinguishes "freshly installed" from "your install."
`/var/lib/pve-cluster` is the SQLite DB underneath it.

> Note: `tar` on `/etc/pve` may emit `file changed as we read it` warnings
> because pmxcfs is live; `--warning=no-file-changed` suppresses the
> noise but the resulting archive is still usable for what we need. For
> a fully-quiesced capture, `systemctl stop pve-cluster && tar … &&
> systemctl start pve-cluster` — overkill on a single-node host.

---

## Layer 5 (out-of-band) — companion artifacts

These don't live on the Proxmox host. Add them to the same baseline
folder so the whole capsule is one self-contained directory:

1. **UniFi backup file.** Settings → System → Backups → Download Backup.
   Copy to the baseline USB at `/${TAG}/unifi-backup-${TAG}.unf`.
2. **BIOS settings reference.** Phone photos of each BIOS screen showing
   the values from `00-phase0-proxmox-bootstrap.md` Step 5.3, copied to
   `/${TAG}/bios-photos/`.
3. **Age public key** (NOT the private key) — copy `~/.sops.yaml` from
   this repo into the baseline as a reminder of which key was active.
   The private key belongs in a password manager and a hardware-
   encrypted USB, *not* here.

---

## Final manifest check

```sh
mount LABEL=pve-baseline /mnt/baseline
ls -lh "/mnt/baseline/${TAG}/"
cat "/mnt/baseline/${TAG}/MANIFEST.md"

# Expected contents:
# - MANIFEST.md
# - rpool-<TAG>.zfs.zst              (Layer 2)
# - tank-<TAG>.zfs.zst               (Layer 2, if tank exists)
# - <clonezilla-folder>/             (Layer 3)
# - pve-config-<TAG>.tgz             (Layer 4)
# - unifi-backup-<TAG>.unf           (Layer 5)
# - bios-photos/                     (Layer 5)
```

Unmount cleanly and unplug:

```sh
umount /mnt/baseline
sync
```

Store the USB SSD somewhere physically separate from the Ryzen. A drawer
in another room, a desk drawer at work, a fire-safe — anywhere that a
"Ryzen catches fire" event doesn't take both copies with it.

---

## Restoration recipes

For each failure mode, the cheapest layer that fixes it.

### "I broke a config in `/etc/network/interfaces` and the host is unreachable"

Boot from the Proxmox installer USB, choose **Debug Mode**, mount `rpool`,
edit the file from the rescue shell. Or — much faster — `zfs rollback` if
nothing important happened since the snapshot:

```sh
# From a rescue shell or local console
zpool import -f rpool
zfs rollback rpool/ROOT/pve-1@phase0-clean-2026-04-27
reboot
```

`zfs rollback` discards everything between the snapshot and now — make
sure that's what you want. For surgical recovery, `zfs clone` the
snapshot to a temporary dataset and copy specific files out.

### "I `zpool destroy`'d rpool"

Boot the Proxmox installer USB → install onto a fresh disk with the same
ZFS-RAID0 / lz4 settings → reboot → from a single-user-ish state:

```sh
mount LABEL=pve-baseline /mnt/baseline
zfs destroy -r rpool/ROOT       # nuke the new fresh-install rootfs
zstd -dc /mnt/baseline/phase0-clean-…/rpool-phase0-clean-….zfs.zst \
  | zfs receive -F rpool
update-grub
proxmox-boot-tool refresh       # re-sync ESP
reboot
```

Then re-attach `tank` from its own stream the same way.

### "The boot NVMe died"

1. Replace the NVMe with a same-or-larger drive.
2. Boot Clonezilla from USB.
3. **device-image → local_dev → restoredisk** → image from
   `/<TAG>/<clonezilla-folder>/` → target = the new NVMe.
4. Reboot. The host should come up exactly as it was at `${TAG}` time.
5. If `tank` is on a separate, undamaged NVMe, it'll auto-import. If
   `tank` died too, restore from its zfs.zst stream as in the previous
   recipe.

### "I want to inspect what changed without rolling back"

```sh
zfs diff rpool/ROOT/pve-1@phase0-clean-2026-04-27 rpool/ROOT/pve-1
# Lists every modified file path between baseline and now.
```

---

## Maintenance

- **Take a new baseline at every phase boundary.** End of Phase 1 (VMs
  exist), end of Phase 2 (k3s up), etc. Re-run this runbook with a new
  `${TAG}`. The on-pool snapshots are free; only Layers 2 and 3 cost
  USB-SSD space.
- **Don't delete old baselines until at least one phase boundary later.**
  Cheap insurance.
- **Once Proxmox Backup Server is up** (planned for late Phase 1 / early
  Phase 2 — see `ARCHITECTURE.md`), VM-level backups move to PBS and
  this runbook stops being the workhorse for VM data. The host-level
  baseline (Layers 3 + 4 + companion artifacts) still applies.

---

## What's done

- A complete, dated baseline of the Proxmox host exists on external
  storage.
- ZFS recursive snapshots are taken and held on-pool for fast rollback.
- Streams of those snapshots are written to a USB SSD with a manifest
  and checksums.
- A Clonezilla full-disk image of the boot NVMe is written next to them.
- A config tarball captures `/etc`, `/etc/pve`, `/var/lib/pve-cluster`,
  and SSH state.
- The UniFi backup, BIOS photos, and age public key reference are
  archived in the same folder.

## What's next

- Phase 1: [`01-phase1-vm-bringup.md`](./01-phase1-vm-bringup.md) — build
  the cloud-init template and provision the first VMs.
- Add an ADR — `docs/decisions/0012-baseline-snapshot-policy.md` —
  recording the layer model and the per-phase cadence above.
