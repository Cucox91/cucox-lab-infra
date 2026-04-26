# Runbook 00 — Phase 0: Proxmox Bootstrap & Network Foundation

> **Goal:** End the runbook with Proxmox VE installed on the Ryzen
> workstation, on the lab `mgmt` VLAN, reachable from the Mac Air, with a ZFS
> pool ready for VM workloads — and the UCG-Max + Office Switch configured to
> isolate the lab from the rest of the home network.
>
> **Estimated time:** 3–4 hours including download/install. Schedule outside
> of work hours; the work-laptop port is touched only briefly and reverted
> immediately.
>
> **Operator:** You, with Claude Code on the Mac Air.

---

## Prerequisites

> **If you're doing the NVMe relocation from the Pi5**, run the hardware
> portion of [`00a-hardware-nvme-relocation.md`](./00a-hardware-nvme-relocation.md)
> (Steps 1–6) first so both NVMes are physically installed and visible in
> BIOS before you begin this runbook. The `tank` pool itself is created
> later (00a Steps 8–13) once Proxmox is up.

Before you start, gather:

- Ryzen workstation, monitor + keyboard for first boot.
- A USB stick (≥ 4 GB) for the Proxmox installer.
- A laptop with the UniFi Network UI accessible (Mac Air on HouseWiFi works).
- Cloudflare account with at least one zone (we don't use it yet, but verify).
- The age private key path `~/.config/sops/age/keys.txt` — generate now if
  you don't have one (see step 0).
- Decided on the house LAN subnet — you'll need to know it. Run on the Mac
  Air: `ipconfig getifaddr en0` and `netstat -rn | grep default` to confirm.

---

## Step 0 — Operator workstation prep (Mac Air)

```sh
# Install required CLIs
brew install \
  age sops \
  terraform \
  ansible \
  kubectl helm \
  cloudflared \
  jq yq

# Generate an age keypair (used by SOPS)
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Note the public key printed to stdout — you'll commit it to .sops.yaml.
grep '# public key:' ~/.config/sops/age/keys.txt
```

Initialize the repo as Git:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
git init
git add .
git commit -m "chore: initial scaffolding"
# Push to your remote of choice (GitHub private, Gitea, etc.) when ready.
```

---

## Step 1 — UniFi: define VLANs (no port changes yet)

Goal of this step: VLANs *exist* in UniFi, but no switch port is using them
yet. Nothing changes on the network until step 3.

In the UniFi Network app on the UCG-Max:

1. **Settings → Networks → Create New Network.**
2. Create three Layer-3 networks with the following parameters:

| Name | VLAN | Gateway/Subnet | DHCP Range | Notes |
|---|---|---|---|---|
| `lab-mgmt` | 10 | `10.10.10.1/24` | `10.10.10.100–199` | Reserve `.10–.49` for static. |
| `lab-cluster` | 20 | `10.10.20.1/24` | `10.10.20.100–199` | Same pattern. |
| `lab-dmz` | 30 | `10.10.30.1/24` | `10.10.30.100–199` | Same pattern. |

For each network: **Auto-Scale Network = off**, **IGMP Snooping = on**,
**Multicast DNS = off** (we don't want mDNS leaking between VLANs).

3. **Settings → Security → Traffic & Firewall Rules.** Build the rule set in
   `ARCHITECTURE.md` § 3.3. The UI's exact path differs across firmware; the
   pattern is one rule per row in that table. Order matters: explicit allows
   above the default-deny.

   Critical rules to confirm exist *before* step 3:
   - `BLOCK: Default LAN ↔ lab-cluster` (both directions)
   - `BLOCK: Default LAN ↔ lab-dmz` (both directions)
   - `BLOCK: lab-cluster → Default LAN` (so the cluster cannot reach the NAS)
   - `BLOCK: lab-dmz → Default LAN`
   - `BLOCK: lab-dmz → lab-mgmt`
   - `ALLOW: lab-mgmt → lab-cluster, lab-dmz` (operator access)

4. Save. Validate the rules render in the firewall table without errors.

> **Verification — nothing should change yet.** Your work laptop, NAS, Pis,
> and house Wi-Fi should be entirely unaffected. Confirm by doing the
> things you'd normally do (open a file on the NAS, ping a Pi, browse the
> web) before continuing.

---

## Step 2 — UniFi: define the `lab-trunk` port profile (still not applied)

1. **Settings → Profiles → Switch Ports → Create New Port Profile.**
2. Name: `lab-trunk`. Native Network: `lab-mgmt`. Tagged Networks:
   `lab-cluster`, `lab-dmz`. PoE: off (the Ryzen doesn't take PoE).
   STP: BPDU Guard ON. Port Isolation: OFF (we need k3s nodes to reach
   each other when Pis join later).
3. Create a second profile, `disabled`, with **Operation: Disabled**. Used
   for unused ports.

---

## Step 3 — UniFi: Wi-Fi for operator access

1. **Settings → WiFi → Create New WiFi Network.**
2. Name: `CucoxLab-Mgmt`. Security: WPA3 Personal (or WPA2/3 mixed if any
   client doesn't support WPA3). Network: `lab-mgmt` (VLAN 10).
3. Hide SSID: optional. Client device isolation: OFF (you may need to reach
   VMs from the Mac Air by IP and from kubectl).
4. Apply. Connect the Mac Air to `CucoxLab-Mgmt` and confirm:

```sh
ipconfig getifaddr en0      # should be 10.10.10.x (DHCP from .100–.199)
ping 10.10.10.1             # gateway reachable
ping 192.168.1.1            # whatever your house gateway is — should be UNREACHABLE
                            # (firewall blocks lab-mgmt → Default LAN by default,
                            # but you've allowed mgmt → all so this depends on rule set;
                            # the important reverse direction is what we test next)
```

> **What this proves:** the Mac Air, when on `CucoxLab-Mgmt`, is in VLAN 10
> with a `10.10.10.x` IP. When on HouseWiFi, it's on Default LAN. Same
> physical AP, two network identities.

If anything in this step misbehaves, fix it before moving on. Steps 4+ assume
working VLAN segmentation.

---

## Step 4 — Bootstrap: temporarily expose the Ryzen port to Default LAN

You need to reach the Proxmox installer's first-boot UI. The cleanest path:

1. In UniFi, set the Ryzen's switch port profile to **Default** (untagged
   only, no tagged VLANs) — *temporarily*.
2. The host will get an IP from the house DHCP during install.
3. After Proxmox is installed and we've moved its mgmt IP to VLAN 10, we
   flip the port profile to `lab-trunk`.

Don't skip the revert in step 9. If you forget, your hypervisor lives on the
house LAN, which contradicts the architecture and the firewall rules.

---

## Step 5 — Proxmox installer

### 5.1 Download

On the Mac Air:

```sh
curl -LO https://enterprise.proxmox.com/iso/proxmox-ve_8.3-1.iso
shasum -a 256 proxmox-ve_8.3-1.iso
# Compare to the SHA256 published at https://www.proxmox.com/en/downloads
```

Use a current 8.x release — adjust the version above. Verify the checksum
against the official site; do not skip this.

### 5.2 Write to USB

```sh
diskutil list                          # find the USB device — be CERTAIN
diskutil unmountDisk /dev/diskN
sudo dd if=proxmox-ve_8.3-1.iso of=/dev/rdiskN bs=4m status=progress
sudo diskutil eject /dev/diskN
```

> **Warning:** `dd` to the wrong disk wipes it. Triple-check `diskutil list`.

### 5.3 BIOS pre-check on the Ryzen workstation

Reboot the Ryzen, enter BIOS, and confirm:

- **SVM (AMD-V) = Enabled** (CPU virtualization).
- **IOMMU = Enabled** (PCIe passthrough later).
- **Above 4G Decoding = Enabled** (modern NIC + GPU support).
- **Resizable BAR = Enabled** (harmless even if unused).
- **Secure Boot = Disabled** (Proxmox kernel modules want this off).
- Boot order: USB first.

Save and reboot from the USB.

### 5.4 Install Proxmox

Walk through the installer:

- **Target disk:** the **original** 1 TB NVMe. If both NVMes are present
  (because you completed the 00a hardware steps), select **only** the
  original drive here — the relocated NVMe is left untouched and becomes
  `tank` in 00a Step 8. Filesystem: **`zfs (RAID0)`** (single disk here;
  this gives you a real ZFS pool and snapshot capability without
  pretending to mirror).
- **ashift:** 12 (default; correct for NVMe).
- **compress:** lz4. **checksum:** on. **copies:** 1.
- **Country/timezone/keymap:** as appropriate.
- **Root password:** strong. Will be replaced with key-based access shortly.
- **Email:** your real email.
- **Management network:**
  - Interface: the 2.5 GbE NIC.
  - Hostname: `lab-prox01.lab.cucox.local`.
  - **IP/CIDR / Gateway / DNS:** *temporarily* take a DHCP-assigned address
    from the house range. We renumber to `10.10.10.10/24` in step 7.

Install. Reboot. Remove the USB.

---

## Step 6 — Proxmox post-install hardening

From the Mac Air on HouseWiFi (because the host is briefly on Default LAN):

```sh
# Replace <PVE_HOUSE_IP> with whatever DHCP gave it.
ssh-copy-id root@<PVE_HOUSE_IP>
ssh root@<PVE_HOUSE_IP>
```

Inside the Proxmox host:

```sh
# Disable the enterprise repo (no subscription, would 401 on apt update)
sed -i 's|^deb |# deb |' /etc/apt/sources.list.d/pve-enterprise.list
sed -i 's|^deb |# deb |' /etc/apt/sources.list.d/ceph.list 2>/dev/null || true

# Add the no-subscription repo
cat > /etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

# Update + upgrade
apt update && apt -y dist-upgrade

# Suppress the "no valid subscription" UI nag (optional, well-known one-liner)
# (Documented and reversible — search "proxmox no subscription nag remove")

# Disable root password SSH; allow only keys
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh

# Time sync sanity
timedatectl status
```

---

## Step 7 — Move Proxmox to the `mgmt` VLAN

Two changes happen in lockstep: the host's IP is renumbered to `10.10.10.10`,
and the switch port profile changes from Default to `lab-trunk`. If they
happen out of order, you lose access.

### 7.1 Configure the host network statically on the bridge

Edit `/etc/network/interfaces` on the Proxmox host. The exact NIC name is
something like `enp5s0`; confirm with `ip a`.

```ini
auto lo
iface lo inet loopback

iface enp5s0 inet manual

auto vmbr0
iface vmbr0 inet static
    address 10.10.10.10/24
    gateway 10.10.10.1
    bridge-ports enp5s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30

# Note: bridge-vlan-aware = yes lets us attach VMs to vmbr0 with a `tag=20` later.
```

DNS:

```sh
cat > /etc/resolv.conf <<'EOF'
nameserver 10.10.10.1
nameserver 1.1.1.1
EOF
```

Do **not** `systemctl restart networking` yet — you'd lose the SSH session.

### 7.2 Coordinated cutover

From the Mac Air, open *two* terminal windows:

- Window A: SSH session to the Proxmox host (currently on its house IP).
- Window B: ready to SSH to `10.10.10.10` after the cutover.

Order of operations:

1. In UniFi: change the Ryzen's switch port profile from **Default** to
   **`lab-trunk`** (native = `lab-mgmt`). Save.
2. In Window A: `ifreload -a` (or `systemctl restart networking` —
   `ifreload` is gentler). Your SSH session will hang/die.
3. Move the Mac Air to `CucoxLab-Mgmt` Wi-Fi (it's on `10.10.10.x` now).
4. In Window B: `ssh root@10.10.10.10`. You're back in.

If step 4 fails: hard-reboot the Ryzen, confirm via the local console that
the bridge came up with `10.10.10.10`. If not, a typo in
`/etc/network/interfaces` is the most common cause; fix from console.

### 7.3 Web UI

From the Mac Air on `CucoxLab-Mgmt`:

```
https://10.10.10.10:8006
```

Login as `root` with the install password. Plan to disable password auth in
favor of TOTP shortly; not in this runbook.

---

## Step 8 — ZFS pool sanity & datasets

```sh
zpool status
# expect: rpool ONLINE, single NVMe disk

zfs list
# expect: rpool, rpool/ROOT, rpool/data already present
```

Create the supplementary datasets per `ARCHITECTURE.md` § 4.2:

```sh
zfs create -o compression=lz4 -o atime=off rpool/iso
zfs create -o compression=lz4 -o atime=off rpool/snapshots

# Tune the VM-disk dataset for database-friendly recordsize.
# rpool/data is created by Proxmox; we adjust properties:
zfs set compression=lz4 rpool/data
zfs set atime=off rpool/data
zfs set recordsize=16K rpool/data

# Cap the ARC at 16 GB (out of 64 GB host RAM)
echo "options zfs zfs_arc_max=17179869184" > /etc/modprobe.d/zfs.conf
update-initramfs -u -k all

# Add storage entries in Proxmox config (or do this from the UI)
pvesm add dir local-iso --path /rpool/iso --content iso,vztmpl
```

A reboot is needed for `zfs_arc_max` to take effect. Do it now (`reboot`)
and reconnect.

> **If the second NVMe is installed and you haven't created `tank` yet:**
> switch to [`00a-hardware-nvme-relocation.md`](./00a-hardware-nvme-relocation.md)
> from Step 8 (identify the new disk) through Step 13 (set tank-vmdata as
> default storage), then return here for Step 9 (lab isolation
> verification).

---

## Step 9 — Confirm the lab is correctly isolated

This is the verification step. Don't move to Phase 1 until every check
passes.

From the Mac Air on `CucoxLab-Mgmt` (VLAN 10):

```sh
ping 10.10.10.10                        # Proxmox: should succeed
ssh root@10.10.10.10 'hostnamectl'      # confirms hostname = lab-prox01
curl -k https://10.10.10.10:8006        # Proxmox UI (HTTP 200/401)
```

From the Mac Air on **HouseWiFi** (Default LAN):

```sh
ping 10.10.10.10                        # SHOULD FAIL — firewall blocks default→mgmt
                                        # except for the operator-IP exception, if any.
                                        # Adjust expectations if you set that exception.
```

From the Proxmox host (VLAN 10):

```sh
# Cluster cannot reach the NAS or house devices yet (no VMs running, but the
# host itself is in mgmt; mgmt → Default is allowed for the operator. The
# real test happens when the first cluster-VLAN VM exists in Phase 1).
ping <NAS_IP>                           # depends on your firewall rules; in
                                        # the recommended posture, mgmt → NAS
                                        # is BLOCKED. Tune rules if not.
```

Switch port profile audit (UniFi UI):

| Port | Expected profile |
|---|---|
| Ryzen | `lab-trunk` (native mgmt 10, tagged 20+30) |
| Work laptop | `Default` (unchanged) |
| NAS | `Default` (unchanged) |
| Pis ×3 | `Default` (unchanged) |
| Unused ports | `disabled` |

If any port in column 1 is wrong, fix before continuing.

---

## Step 10 — Commit and close out Phase 0

In the repo:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"

# Capture the actual VLAN/firewall state from UniFi as a markdown snapshot
# (you'll edit ARCHITECTURE.md to match if anything differs from the design).
git add ARCHITECTURE.md docs/
git commit -m "feat(phase0): proxmox installed, lab VLANs live, mgmt isolated"
```

Open `docs/decisions/0001-hypervisor-choice.md` and write the ADR up properly
(the template is short — context, decision, consequences). Same for 0002,
0003, 0004 referenced in `ARCHITECTURE.md` § 12.

---

## What's done / what's next

**Done in Phase 0:**

- Three lab VLANs configured on the UCG-Max with deny-default firewall.
- `CucoxLab-Mgmt` SSID broadcasting on VLAN 10.
- Office Switch port profiles applied: Ryzen on `lab-trunk`, others
  unchanged, unused ports disabled.
- Proxmox VE installed on the Ryzen with ZFS root, on `10.10.10.10/24`.
- ZFS datasets prepared, ARC capped, repos set to no-subscription.
- Repo initialized; SOPS+age key generated.

**Next — Phase 1:** [`01-phase1-vm-bringup.md`](./01-phase1-vm-bringup.md) —
build the Ubuntu 24.04 cloud-init template, write the Terraform module,
spin up `lab-cp01..03` and `lab-wk01..02` from code.

---

## Rollback

If you need to abort Phase 0:

1. UniFi: switch the Ryzen port profile back to **Default**, disable
   `CucoxLab-Mgmt` Wi-Fi, leave the VLANs defined (they affect nothing while
   no port carries them).
2. The Proxmox host is now isolated from any network until you re-flip the
   port profile or re-IP it. You can wipe and restart any time — nothing
   else depends on it yet.
