# Runbook 01 — Phase 1: VM Template & Terraform-driven Bringup

> **Goal:** End the runbook with a single golden VM template
> (`tmpl-ubuntu-24-04`) on Proxmox and the six Phase 1 VMs from
> ARCHITECTURE.md § 4.4 cloned, booted, on their correct VLANs, with static
> IPs and key-based SSH from the Mac Air. No k3s yet — that's runbook 02.
>
> **Estimated time:** 2–3 hours, of which ~30 minutes is template-build and
> the rest is Terraform iteration. Faster on the second pass.
>
> **Operator:** Raziel, with Claude Code on the Mac Air, on SSID
> `CucoxLab-Mgmt` (VLAN 10).

---

## What this runbook implements

| ARCHITECTURE.md ref | Implemented here |
|---|---|
| § 4.3 — VM template strategy | Build `tmpl-ubuntu-24-04` once, by hand, via `qm`. |
| § 4.4 — VM inventory (Phase 1 target state) | Six VMs, cloned by Terraform from the template, on `cluster` (VLAN 20) and `dmz` (VLAN 30). |
| § 8.1 — Tooling | bpg/proxmox provider (per ADR-0010-A); cloud-init for first-boot customization; SOPS for the Proxmox API token. |
| § 9 — Secrets | Proxmox API token & cloud-init password (if any) live in `terraform/proxmox/secrets.auto.tfvars.enc.yaml`, SOPS-encrypted. |
| ADR-0010 / ADR-0010-A | Document the provider choice. ADR-0010 (Telmate) is superseded by ADR-0010-A (bpg) after Telmate panicked on Proxmox 8.x. |

What this runbook does **not** do: install k3s, install Cilium, install
anything cluster-shaped. Those are runbook 02.

---

## Prerequisites

- Runbook 00 (Phase 0) completed end-to-end. `lab-prox01` is reachable at
  `10.10.10.10` from the Mac Air on `CucoxLab-Mgmt`.
- **(Phase 1 deviation, see [ADR-0011](../decisions/0011-phase1-single-pool-deviation.md))**
  The second NVMe relocation from runbook 00a is deferred. VMs run on
  `rpool/data` (Proxmox storage `local-zfs`, created by the Proxmox
  installer) for now. ADR-0009's two-pool ZFS layout remains the target
  end-state — the migration plan is in ADR-0011 § "Migration to tank".
  Verify the storage that *does* exist:

  ```sh
  ssh root@10.10.10.10 'pvesm status | grep -E "local-zfs|local-iso"'
  # expect both rows, both `active`. A `tank-vmdata` row is intentionally
  # absent under this deviation.
  ```

  If `local-zfs` is missing, your Proxmox install diverged from the
  defaults — fix that first; every `qm` and Terraform step below assumes it.

- ZFS pool `rpool` is healthy (`zpool status` is `ONLINE`, no errors).
  `rpool/data` is the storage backing `local-zfs` and holds VM disks for
  the duration of this deviation.
- Mac Air has `terraform`, `sops`, `age`, `jq`, `yq` installed (Phase 0
  Step 0). Confirm:

  ```sh
  terraform version    # ≥ 1.7
  sops --version       # ≥ 3.8
  age --version
  ```

- Age public key is committed to `.sops.yaml` (Phase 0). The private key at
  `~/.config/sops/age/keys.txt` is **not** in the repo.
- Repo state matches `main` at the commit that closes Phase 0.

---

## Step 0 — Repo scaffold for Phase 1

On the Mac Air:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
git switch -c phase1-vm-bringup     # work on a branch; PR into main when stable

mkdir -p terraform/proxmox
mkdir -p terraform/modules/vm
touch terraform/proxmox/.gitkeep terraform/modules/vm/.gitkeep
```

You'll fill in the Terraform later in Step 5. For now, the directories
exist so the runbook commands resolve.

---

## Step 1 — Proxmox API token for Terraform

Terraform needs a credential to talk to the Proxmox API (port 8006). Use a
**dedicated API token** — never the root password — so you can rotate it
independently.

### 1.1 Create a Proxmox role + user + token

SSH to the Proxmox host (`ssh root@10.10.10.10`) and run:

```sh
# Create a role with the privileges Terraform needs to clone VMs and
# manage cloud-init disks. This is broader than strictly required, but
# narrower than full admin.
pveum role add TerraformProv -privs \
  "Datastore.AllocateSpace Datastore.Audit \
   Pool.Allocate Sys.Audit Sys.Console Sys.Modify \
   VM.Allocate VM.Audit VM.Clone VM.Config.CDROM \
   VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk \
   VM.Config.HWType VM.Config.Memory VM.Config.Network \
   VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt \
   SDN.Use"

# Create a Proxmox user `terraform@pve` (PVE realm — local, not PAM).
pveum user add terraform@pve --comment "Terraform bpg/proxmox provider"

# Bind the role to / for that user (root path = whole datacenter).
pveum aclmod / -user terraform@pve -role TerraformProv

# Issue an API token. `--privsep 0` means the token inherits the user's
# permissions directly. With privsep=1 you'd have to ACL the token too.
pveum user token add terraform@pve provider --privsep 0
# ── prints the token ID + secret. CAPTURE THE SECRET NOW; it is only
#    shown once.
```

The output looks like:

```
┌──────────────┬──────────────────────────────────────┐
│ key          │ value                                │
├──────────────┼──────────────────────────────────────┤
│ full-tokenid │ terraform@pve!provider               │
│ value        │ 11111111-2222-3333-4444-555555555555 │
└──────────────┴──────────────────────────────────────┘
```

Two values to capture: the **token ID** (`terraform@pve!provider`) and the
**secret UUID**.

### 1.2 Stash the token in SOPS

On the Mac Air:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"

# .sops.yaml should already encrypt anything under terraform/**/secrets*.
# If not, fix it before continuing — Phase 0 ADR-0008 made this load-bearing.
grep -A2 'terraform' .sops.yaml || echo "MISSING — go fix .sops.yaml first"

cat > terraform/proxmox/secrets.auto.tfvars.enc.yaml <<'EOF'
# bpg/proxmox provider format (see ADR-0010-A). The api_token is a
# joined string "<full-tokenid>=<secret>" — bpg accepts only this shape.
proxmox_endpoint:     "https://10.10.10.10:8006/"
proxmox_api_token:    "terraform@pve!provider=REPLACE_ME_WITH_UUID_FROM_PVEUM_OUTPUT"
proxmox_tls_insecure: true
EOF

# Encrypt in place.
sops --encrypt --in-place terraform/proxmox/secrets.auto.tfvars.enc.yaml

# Verify it actually encrypted (file should now contain `sops:` metadata).
head -5 terraform/proxmox/secrets.auto.tfvars.enc.yaml
```

> **Endpoint URL format:** bpg wants `https://<host>:8006/` with **no**
> `/api2/json` suffix — the provider appends that itself. Telmate
> required the suffix; bpg breaks if you include it.

> **Why YAML inside a `.tfvars` filename?** The Telmate provider doesn't read
> SOPS YAML directly — we'll convert at apply time using `sops -d` piped
> into Terraform via env vars. See Step 6.2. The `.auto.tfvars` extension is
> a hint for future-you that this is the variables file.

`gitleaks` and the pre-commit hook from ADR-0008 will refuse to commit the
plaintext form. The encrypted form is safe to commit.

---

## Step 2 — Download the Ubuntu cloud image to the Proxmox host

We use Ubuntu Server 24.04 LTS (Noble) as the base. The cloud image — not
the installer ISO — is the small, pre-prepared qcow2 designed for cloud-init.

On the Proxmox host:

```sh
cd /rpool/iso       # the dataset created in Phase 0 step 8

# Pull the canonical noble cloud image. Ubuntu publishes daily and stable
# variants; use the stable LTS path.
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Verify the SHA256 against Canonical's published checksum.
wget https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
grep noble-server-cloudimg-amd64.img SHA256SUMS | sha256sum -c -
# expect: noble-server-cloudimg-amd64.img: OK
```

If the checksum doesn't match, **stop**. Don't build a template from a
tampered image.

> **Why the qcow2 image and not the ISO?** The ISO walks an interactive
> installer; the cloud image is already an installed system, ready for
> cloud-init to customize on first boot. Templates built from cloud images
> clone in seconds and have no installer artifacts.

---

## Step 3 — Build the golden template `tmpl-ubuntu-24-04`

This is the only VM in the lab we build by hand. Everything else clones
from it. The ARCHITECTURE.md § 4.3 commitment is "we never click VMs into
existence after Phase 0 is done" — this template is the line in the sand.

### 3.1 Pick a VMID

By convention, templates live in the `9000–9099` range so they sort to
the bottom of the Proxmox UI and never collide with workload VMs (which
will live in `100–199` per § 4.4).

| VMID | Purpose |
|---|---|
| `9000` | `tmpl-ubuntu-24-04` (this template) |

### 3.2 Create the template

On the Proxmox host:

```sh
# Create the VM shell. Choose memory/cpu defaults that are sane for clones
# (each cloned VM overrides anyway).
qm create 9000 \
  --name tmpl-ubuntu-24-04 \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --efidisk0 local-zfs:0,format=raw,efitype=4m,pre-enrolled-keys=0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --serial0 socket --vga serial0 \
  --agent enabled=1 \
  --ostype l26

# Import the cloud image as a disk on `local-zfs` (rpool/data).
qm importdisk 9000 /rpool/iso/noble-server-cloudimg-amd64.img local-zfs

# Attach the imported disk as scsi0 (boot disk) with discard for ZFS TRIM.
qm set 9000 --scsi0 local-zfs:vm-9000-disk-1,discard=on,iothread=1,ssd=1

# Add a cloud-init drive on ide2 (Proxmox's default for cloud-init).
qm set 9000 --ide2 local-zfs:cloudinit

# Boot from the imported disk.
qm set 9000 --boot order=scsi0

# Resize to 20 GB (cloud images ship at ~3.5 GB; cloud-init grows the FS
# on first boot to fill the disk).
qm resize 9000 scsi0 20G
```

A few choices worth understanding rather than copy-pasting blind:

| Flag | Why |
|---|---|
| `--cpu host` | Exposes the full 5950X feature set to the guest. Required for any perf work later (Phase 5). The cost is no live-migration to a different CPU, which we don't have anyway. |
| `--machine q35` | Modern PCIe machine type. Required for the GPU passthrough in Phase 5; trying to retrofit later is painful. |
| `--bios ovmf` + `--efidisk0` | UEFI boot. Matches modern distros and is required for q35. |
| `--scsihw virtio-scsi-single` + `iothread=1` | One I/O thread per disk. Better latency under contention; relevant once we run databases. |
| `--serial0 socket` + `--vga serial0` | Cloud-init prints to serial; we want `qm terminal 9000` to work without a graphical console. |
| `--agent enabled=1` | qemu-guest-agent — **the package itself is installed by cloud-init at first boot of every clone, not baked into the template**. See § 3.3 for why and § 5.0 for the snippet. Lets Proxmox query IPs, do graceful shutdowns. |
| `--net0 ... bridge=vmbr0` | Template lives on the **mgmt** bridge during build (vmbr0 = native VLAN 10 per Phase 0 § 7.1). Clones for cluster/dmz roles override `bridge` to `vmbr20` / `vmbr30` in Terraform. No `tag=N` — we use the traditional Linux VLAN model (one bridge per VLAN), not VLAN-aware bridges. See ADR-0012. |

### 3.3 Sanity-check the machine-id (no apt, no DNS)

The earlier draft of this runbook ran `virt-customize --install
qemu-guest-agent --truncate /etc/machine-id` here, which reliably fails
on a freshly-VLAN'd Proxmox host: the libguestfs appliance gets user-mode
NAT but its DNS forwarder breaks (`Temporary failure resolving
archive.ubuntu.com`). The right architectural answer is to install
`qemu-guest-agent` via cloud-init at first boot — done once in § 5.0,
applied automatically to every clone. **No baked apt step here.**

That leaves only the machine-id concern. If `/etc/machine-id` in the
cloud image is non-empty, every clone inherits the same ID and downstream
state (systemd journals, DHCP leases, k8s node-id heuristics) gets
confused. Modern Ubuntu cloud images ship with an empty `machine-id`
specifically to avoid this — but verify, don't assume.

```sh
# Install libguestfs tools on the Proxmox host (once).
apt -y install libguestfs-tools

# Discover the disk path Proxmox attached. With local-zfs (rpool/data) it's a zvol.
DISK=$(qm config 9000 | awk -F'[ ,]' '/^scsi0:/ {print $2}')
echo "scsi0 maps to: $DISK"
# local-zfs:vm-9000-disk-1     →   /dev/zvol/rpool/data/vm-9000-disk-1
# local:9000/vm-9000-disk-1.qcow2 →  /var/lib/vz/images/9000/vm-9000-disk-1.qcow2

# Stop the VM (must be off for libguestfs to lock the device).
qm stop 9000 2>/dev/null || true

# Read-only inspection — needs no DNS, installs nothing.
guestfish --ro -a /dev/zvol/rpool/data/vm-9000-disk-1 -i cat /etc/machine-id | wc -c
```

| Output | Meaning | Action |
|---|---|---|
| `1` | `/etc/machine-id` is empty (just a trailing newline). The cloud image is well-behaved. | **Do nothing here.** Skip to § 3.4. |
| `33` | A 32-char machine-id is baked in. Every clone would share it. | Truncate it (next snippet), then go to § 3.4. |

If you got `33`, run only the truncate — no apt:

```sh
virt-customize -a /dev/zvol/rpool/data/vm-9000-disk-1 \
  --truncate /etc/machine-id
# `--truncate` is a local file op — no DNS dependency, no apt repo fetch.
```

> **If `virt-customize` or `guestfish` fails with "Permission denied" on
> the zvol:** ensure the VM is fully stopped (`qm status 9000` shows
> `stopped`) and that no other process holds the device
> (`lsof /dev/zvol/rpool/data/vm-9000-disk-1` should be empty). If
> `qm template 9000` has already been run, the zvol is read-only — undo
> with `zfs set readonly=off rpool/data/vm-9000-disk-1`, fix, then
> re-template.

> **Why not bake the package?** Saving 30 s of first-boot time per VM
> isn't worth the failure mode when a future fresh-install lab walkthrough
> hits the same DNS bug. Cloud-init has real network on the cluster VLAN;
> libguestfs has flaky NAT'd DNS. Use the right tool.

### 3.4 Convert to a template

```sh
qm template 9000
```

After this, VMID 9000 is read-only and clones become near-instant
(linked-clone disk semantics on ZFS).

### 3.5 Sanity-clone (one-shot, throwaway)

Before introducing Terraform, prove the template + cloud-init flow works
manually. **You must complete § 5.0** (snippet file on Proxmox host)
before this clone — the test exercises both the template *and* the
`cicustom` cloud-init path.

> If you'd rather defer the §5.0 snippet creation until you reach Step 5,
> drop the `--cicustom` line from `qm set` below. The template clone will
> still come up and SSH will work; `qemu-guest-agent` just won't install,
> so don't expect `systemctl is-active qemu-guest-agent` to pass. That's
> a partial test of the template only.

```sh
qm clone 9000 999 --name probe-clone --full
qm set 999 --ipconfig0 ip=10.10.10.99/24,gw=10.10.10.1 \
           --nameserver "10.10.10.1 1.1.1.1" \
           --searchdomain lab.cucox.local \
           --ciuser ubuntu \
           --sshkeys /root/.ssh/authorized_keys \
           --net0 virtio,bridge=vmbr0 \
           --cicustom vendor=local:snippets/cucox-base.yaml
qm start 999

# Watch it come up.
qm terminal 999     # exits with Ctrl-O Ctrl-X

# From the Mac Air, once it has an IP:
ssh ubuntu@10.10.10.99 'uname -a; systemctl is-active qemu-guest-agent'
# First boot includes apt-update + qemu-guest-agent install. Allow ~45 s
# from `qm start` before SSH'ing — earlier and the agent may still be
# installing.
```

> **Why `--nameserver` matters.** Without it, Proxmox writes a cloud-init
> network-config with no DNS resolver, the VM's `/etc/resolv.conf` ends
> up empty, and cloud-init's `apt-get update` hangs ~5 minutes on DNS
> retries before falling through with empty package lists — at which
> point `apt-get install qemu-guest-agent` fails with "Unable to locate
> package". The Terraform path in § 5.2 sets the same field via
> `nameserver = "10.10.10.1 1.1.1.1"` so production VMs are fine; the
> manual `qm set` is the one that has to spell it out.

Expected: SSH works on first try, guest agent ends up `active`. If it
doesn't:

- SSH works but guest agent is `inactive`/`not-found` → cloud-init
  couldn't run the snippet. Check `sudo journalctl -u cloud-init` inside
  the VM and `cat /var/lib/vz/snippets/cucox-base.yaml` on the host.
- SSH fails outright → the template's networking or SSH key handling is
  broken. **Fix the template, not the clone.**

Then:

```sh
qm stop 999 && qm destroy 999
```

Don't move to Terraform until this manual clone works end-to-end.

---

## Step 4 — Snapshot the host state

Take a Proxmox-side snapshot of the template before we let Terraform start
creating siblings of it. This is a recovery point if Phase 1 goes sideways
and you want to start over.

```sh
# Single-pool deviation: only rpool/data exists right now. When tank
# arrives (per ADR-0011 migration plan), add a `tank/vmdata@phase1-pre-terraform`
# snapshot at that point too.
zfs snapshot rpool/data@phase1-pre-terraform
zfs list -t snapshot
```

To roll back later (from console only — destructive):

```sh
zfs rollback rpool/data@phase1-pre-terraform
```

---

## Step 5 — Define the six VMs in Terraform

### 5.0 One-time Proxmox prep: cloud-init snippet for shared baseline

Each clone needs `qemu-guest-agent` installed at first boot (replaces the
libguestfs approach we abandoned in § 3.3). cloud-init reads two layers:

- **Per-VM** (`user-data`) — Proxmox auto-generates this from Telmate's
  `ciuser` / `sshkeys` / `ipconfig0` fields. Different per VM.
- **Shared baseline** (`vendor-data`) — a snippet file you place once on
  the Proxmox host. cloud-init merges it on top of `user-data`.

We put the package install in the shared layer so every clone gets it
without duplicating cloud-init blobs in Terraform.

**On the Proxmox host:**

```sh
# 1. Verify `local` storage permits the `snippets` content type.
pvesm status -content snippets

# If `local` is in the output → done.
# If not → enable it:
#   pvesm set local --content iso,vztmpl,backup,snippets
#   pvesm status -content snippets        # confirm `local` now appears

# 2. Create the snippet directory + file.
mkdir -p /var/lib/vz/snippets

cat > /var/lib/vz/snippets/cucox-base.yaml <<'EOF'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

# 3. Sanity-check.
ls -l /var/lib/vz/snippets/cucox-base.yaml
cat /var/lib/vz/snippets/cucox-base.yaml
```

The snippet is referenced from Terraform via `cicustom = "vendor=local:snippets/cucox-base.yaml"` in § 5.2. Format breakdown:

| Token | Meaning |
|---|---|
| `vendor` | Which cloud-init layer to override. `vendor-data` *merges with* the auto-generated `user-data`, preserving Telmate's `ciuser`/`sshkeys`. **Do not use `user=` here** — it would replace the auto-generated `user-data` and your VMs would come up without SSH keys. |
| `local` | Proxmox storage ID (the directory storage at `/var/lib/vz`). |
| `snippets/cucox-base.yaml` | Path inside that storage → `/var/lib/vz/snippets/cucox-base.yaml`. |

> **Future-you reading this in six months:** to add a new shared-baseline
> behavior (say, a sysctl tweak), edit `cucox-base.yaml` in place. New
> clones pick it up automatically. Existing VMs are unaffected — cloud-init
> only runs the snippet on first boot.

### 5.1 Provider + variable plumbing

Create `terraform/proxmox/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"   # pin per ADR-0010-A (replaces Telmate)
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token   # joined string: "<id>=<secret>"
  insecure  = var.proxmox_tls_insecure
}
```

Create `terraform/proxmox/variables.tf`:

```hcl
variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API base URL — e.g. https://10.10.10.10:8006/ (no /api2/json suffix; bpg adds it)."
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "Joined token: <user>@<realm>!<token-id>=<secret-uuid>."
}

variable "proxmox_tls_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  type    = string
  default = "lab-prox01"
}

variable "template_vmid" {
  type        = number
  default     = 9000
  description = "VMID of the golden template (tmpl-ubuntu-24-04). bpg clones by VMID, not name."
}

variable "ssh_public_key" {
  type        = string
  description = "Contents of the operator's public key — not a path."
}

# CIDR-style notation; cloud-init takes "<ip>/<prefix>"
variable "vms" {
  type = map(object({
    vmid    = number
    cores   = number
    memory  = number
    disk_gb = number
    bridge  = string  # one of vmbr0 / vmbr20 / vmbr30 — see ADR-0012
    ip      = string  # e.g. "10.10.20.21/24"
    gw      = string
    role    = string  # informational tag only
  }))
}
```

Create `terraform/proxmox/terraform.tfvars`:

```hcl
ssh_public_key = "ssh-ed25519 AAAA... raziel@cucox-mac"   # paste yours

vms = {
  "lab-cp01"   = { vmid = 121, cores = 4, memory =  8192, disk_gb = 40, bridge = "vmbr20", ip = "10.10.20.21/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-cp02"   = { vmid = 122, cores = 4, memory =  8192, disk_gb = 40, bridge = "vmbr20", ip = "10.10.20.22/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-cp03"   = { vmid = 123, cores = 4, memory =  8192, disk_gb = 40, bridge = "vmbr20", ip = "10.10.20.23/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-wk01"   = { vmid = 131, cores = 6, memory = 16384, disk_gb = 80, bridge = "vmbr20", ip = "10.10.20.31/24", gw = "10.10.20.1", role = "k3s-agent"  }
  "lab-wk02"   = { vmid = 132, cores = 6, memory = 16384, disk_gb = 80, bridge = "vmbr20", ip = "10.10.20.32/24", gw = "10.10.20.1", role = "k3s-agent"  }
  "lab-edge01" = { vmid = 141, cores = 2, memory =  4096, disk_gb = 20, bridge = "vmbr30", ip = "10.10.30.21/24", gw = "10.10.30.1", role = "edge"      }
}
```

VMID assignments: `1<role-digit><instance>`. CP=2x, WK=3x, EDGE=4x. Stable
mental model, doesn't collide with the template at `9000`.

### 5.2 The VM resource

Create `terraform/proxmox/main.tf`:

```hcl
# bpg/proxmox provider — see ADR-0010-A for migration history from Telmate.
# Resource type: proxmox_virtual_environment_vm (different from Telmate's proxmox_vm_qemu).
resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.vms

  name      = each.key
  vm_id     = each.value.vmid
  node_name = var.proxmox_node

  # Clone from the golden template by VMID (bpg requires the number).
  clone {
    vm_id = var.template_vmid
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores   = each.value.cores
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # Disk override on top of the cloned template's disk.
  # Phase 1 deviation per ADR-0011: storage is local-zfs until tank/vmdata exists.
  disk {
    interface    = "scsi0"
    datastore_id = "local-zfs"
    size         = each.value.disk_gb   # GB as a number, NOT "40G"
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    model  = "virtio"
    bridge = each.value.bridge   # vmbr0 (mgmt) / vmbr20 (cluster) / vmbr30 (dmz) — ADR-0012
    # No vlan_id — the kernel VLAN sub-interface on the NIC tags egress for vmbr20/30
    # unconditionally. vmbr0 is native VLAN 10 via the lab-trunk port profile.
  }

  # Cloud-init configuration (replaces Telmate's flat ipconfig0/ciuser/sshkeys/etc).
  initialization {
    # Cloud-init drive storage. bpg defaults to "local-lvm" which doesn't exist
    # on a ZFS-only install — point at local-zfs explicitly. (ADR-0011 deviation.)
    datastore_id = "local-zfs"

    # Per-VM bits go into auto-generated user-data.
    user_account {
      username = "ubuntu"
      keys     = [trimspace(var.ssh_public_key)]
    }
    ip_config {
      ipv4 {
        address = each.value.ip   # CIDR form: "10.10.20.21/24"
        gateway = each.value.gw
      }
    }
    # DNS resolver — per-VLAN, always the VLAN's own gateway first.
    # cluster: 10.10.10.1 reachable via cluster→mgmt allow. dmz: 10.10.30.1
    # is the same-VLAN gateway forwarder (no zone crossing). dmz cannot
    # reach public DNS — ARCH §3.3 has no dmz→Internet rule — so the
    # gateway forwarder is the only working path. (Earlier draft tried
    # ["1.1.1.1","1.0.0.1"] for dmz; UCG-Max drops dmz→Internet on UDP/TCP 53.)
    dns {
      servers = each.value.bridge == "vmbr30" ? ["10.10.30.1", "1.1.1.1"] : ["10.10.10.1", "1.1.1.1"]
      domain  = "lab.cucox.local"
    }

    # Shared baseline (qemu-guest-agent install, etc.) via vendor-data — see § 5.0.
    # bpg's `vendor_data_file_id` is the equivalent of Telmate's `cicustom = "vendor=..."`.
    # NB: the snippet file MUST exist at /var/lib/vz/snippets/cucox-base.yaml on the host.
    vendor_data_file_id = "local:snippets/cucox-base.yaml"
  }

  # Match the golden template's hardware shape (q35 + ovmf for UEFI).
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  tags = ["phase1", each.value.role]

  # Don't churn on every plan if Proxmox re-renders the NIC MAC or reorders disks.
  lifecycle {
    ignore_changes = [
      network_device,
      disk,
    ]
  }
}

output "vm_ips" {
  value = { for k, v in var.vms : k => v.ip }
}
```

Differences worth understanding (Telmate → bpg):

| Telmate (was) | bpg (is) |
|---|---|
| `proxmox_vm_qemu` | `proxmox_virtual_environment_vm` |
| `vmid = 121` | `vm_id = 121` |
| `target_node = ...` | `node_name = ...` |
| `clone = "tmpl-name"` | `clone { vm_id = 9000 }` (block, by ID) |
| `cpu = "host"` + `cores = N` + `sockets = 1` | `cpu { cores = N, sockets = 1, type = "host" }` |
| `memory = N` | `memory { dedicated = N }` |
| `disk { size = "40G" }` | `disk { size = 40 }` (number) |
| `network { bridge = X }` | `network_device { bridge = X }` |
| `ipconfig0`, `ciuser`, `sshkeys`, `nameserver`, `searchdomain` (flat) | `initialization { user_account { keys = [...] } ip_config { ipv4 { ... } } dns { ... } }` (nested) |
| `cicustom = "vendor=local:snippets/foo.yaml"` | `vendor_data_file_id = "local:snippets/foo.yaml"` |
| `tags = "a;b"` (semicolon string) | `tags = ["a", "b"]` (list) |

> **Why bpg, not Telmate?** Telmate v2.9.14 panicked on Proxmox 8.x's API
> response shape during the first `terraform apply` of this runbook. The
> migration history is in
> [ADR-0010-A](../decisions/0010A-bpg-proxmox-provider-migration.md).
> ADR-0010 (the original Telmate choice) is now marked superseded.

### 5.3 `.gitignore` hygiene

Append to the repo's `.gitignore` if not already present:

```gitignore
# Terraform local state
**/.terraform/
**/.terraform.lock.hcl
**/terraform.tfstate
**/terraform.tfstate.backup
**/terraform.tfvars      # contains your SSH key + non-secret VM map; ok to commit if you prefer

# SOPS plaintext should never appear; encrypted *.enc.yaml IS committed.
**/secrets.auto.tfvars
```

Decide once whether `terraform.tfvars` is committed. The VM map is not
secret, but the SSH public key is your call. Recommended: commit it; it's
a public key.

---

## Step 6 — Apply

### 6.1 Initialize

```sh
cd terraform/proxmox
terraform init
```

If `terraform init` fails on the provider, check the version pin in
`versions.tf` (`bpg/proxmox ~> 0.66`). bpg publishes ~monthly.

### 6.2 Plan with secrets injected at runtime

We never write the plaintext token to disk. Use SOPS at apply time:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/terraform/proxmox"

# Decrypt to a tmpfs path that gets cleaned up by the shell on exit.
SECRETS=$(mktemp -t pmsecrets.XXXX.json)
trap "rm -f $SECRETS" EXIT
sops --decrypt secrets.auto.tfvars.enc.yaml | yq -o=json > "$SECRETS"

# Pass each var via -var. The token is short-lived in env.
terraform plan \
  -var "proxmox_endpoint=$(jq -r .proxmox_endpoint $SECRETS)" \
  -var "proxmox_api_token=$(jq -r .proxmox_api_token $SECRETS)" \
  -var "proxmox_tls_insecure=$(jq -r .proxmox_tls_insecure $SECRETS)"
```

The first plan should show **6 resources to add**, and nothing else.

The `-var` block above is verbose. Wrap it once in a script you can
reuse for `plan`, `apply`, and `destroy`:

```sh
mkdir -p ../../scripts
cat > ../../scripts/tf.sh <<'EOF'
#!/usr/bin/env bash
# Usage: scripts/tf.sh <plan|apply|destroy> [extra terraform args]
# Variable shape per ADR-0010-A (bpg/proxmox).
set -euo pipefail
: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

cd "$(dirname "$0")/../terraform/proxmox"

SECRETS=$(mktemp -t pmsecrets.XXXX.json)
trap 'rm -f "$SECRETS"' EXIT
sops --decrypt secrets.auto.tfvars.enc.yaml | yq -o=json > "$SECRETS"

terraform "$@" \
  -var "proxmox_endpoint=$(jq -r .proxmox_endpoint "$SECRETS")" \
  -var "proxmox_api_token=$(jq -r .proxmox_api_token "$SECRETS")" \
  -var "proxmox_tls_insecure=$(jq -r .proxmox_tls_insecure "$SECRETS")"
EOF
chmod +x ../../scripts/tf.sh
```

Then `plan` / `apply` / `destroy` are one-liners:

### 6.3 Apply

```sh
# From terraform/proxmox/, using the wrapper script:
../../scripts/tf.sh apply
# Type `yes` at the confirmation prompt.

# Or, if you'd rather not use the wrapper, repeat the full -var block from §6.2
# but with `apply` instead of `plan`:
#   terraform apply \
#     -var "proxmox_endpoint=$(jq -r .proxmox_endpoint $SECRETS)" \
#     -var "proxmox_api_token=$(jq -r .proxmox_api_token $SECRETS)" \
#     -var "proxmox_tls_insecure=$(jq -r .proxmox_tls_insecure $SECRETS)"
```

bpg parallelises clone operations more aggressively than Telmate did, so
all 6 VMs may be in-flight at once. Expect ~3–4 minutes total.

> **If apply hangs at "Waiting for the VM to start":** the most common
> cause is that cloud-init couldn't reach the VLAN's gateway. Check on the
> Proxmox host: `qm config <vmid> | grep -E 'net0|ipconfig0'` should show
> the right `bridge=vmbr20` (or `vmbr30`) and matching IP. If `bridge=`
> is wrong, the VM is on the wrong VLAN — fix the tfvars `bridge` field
> and re-apply. If the bridge is right but the VM still can't reach its
> gateway, run `ip -br link show type bridge` on the host: missing `vmbr20`
> or `vmbr30` means Phase 0 § 7.1 didn't apply correctly.

---

## Step 7 — Verify

From the Mac Air on `CucoxLab-Mgmt`:

```sh
# All 6 should answer.
for ip in 10.10.20.21 10.10.20.22 10.10.20.23 10.10.20.31 10.10.20.32 10.10.30.21; do
  printf '%-15s ' "$ip"
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 ubuntu@$ip 'hostname; ip -br a | grep -v lo'
done
```

Expected output (abbreviated):

```
10.10.20.21    lab-cp01
               ens18 UP 10.10.20.21/24 ...
10.10.20.22    lab-cp02
...
10.10.30.21    lab-edge01
               ens18 UP 10.10.30.21/24 ...
```

If a VM gets the wrong IP, the cloud-init network config didn't apply. Two
common fixes:

1. The cloud-init drive on the template wasn't `ide2` (Telmate's default).
   Inspect: `qm config <vmid> | grep ide2`.
2. The VM was cloned before the template snapshot was finalized. Destroy
   and `terraform apply` again; full clones are cheap on ZFS.

### 7.1 VLAN sanity from inside a VM

```sh
ssh ubuntu@10.10.20.21
sudo apt -y install traceroute
traceroute -n 10.10.10.10           # mgmt — should be ALLOWED (mgmt rules)
traceroute -n 10.10.30.21           # cluster → dmz — depends on FW; check § 3.3
ping -c 2 192.168.1.1               # default LAN — MUST FAIL (deny rule)
```

If `ping 192.168.1.1` succeeds from a cluster VM, the firewall rule
`cluster → Default LAN` is leaking. Fix UCG-Max rules before continuing.

### 7.2 Storage sanity

```sh
ssh ubuntu@10.10.20.21 'lsblk; df -hT /'
# expect: scsi disk visible, root fs ext4 (cloud image default), ~40 GB.
```

---

## Step 8 — Snapshots (per-VM, post-bringup)

Before we hand these VMs to k3s, snapshot them in the clean state:

```sh
ssh root@10.10.10.10 '
  for v in 121 122 123 131 132 141; do
    qm snapshot "$v" "phase1-base" --description "post Terraform apply, pre k3s"
  done
  qm listsnapshot 121
'
```

A failed k3s install can be reverted to `phase1-base` in one command per
VM rather than a full re-clone:

```sh
qm rollback <vmid> phase1-base
```

---

## Step 9 — Commit & merge

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"

git add terraform/proxmox/ docs/runbooks/01-phase1-vm-bringup.md docs/decisions/0010-terraform-proxmox-provider.md
pre-commit run --all-files     # ADR-0008 hooks: gitleaks, yamllint, sops check

git commit -m "feat(phase1): VM template + Terraform bringup of 6 Phase 1 VMs

- tmpl-ubuntu-24-04 built from Ubuntu 24.04 cloud image
- bpg/proxmox provider (see ADR-0010-A; supersedes ADR-0010)
- 6 VMs cloned: 3 cp + 2 wk on cluster VLAN, 1 edge on dmz VLAN
- Proxmox API token managed via SOPS"
git push origin phase1-vm-bringup
# open PR; merge into main once the verification block in Step 7 passes.
```

---

## Quick reference

### VMID → name table

| VMID | Name | VLAN | IP |
|---|---|---|---|
| 9000 | tmpl-ubuntu-24-04 | 10 (template only; never booted) | — |
| 121 | lab-cp01 | 20 | 10.10.20.21 |
| 122 | lab-cp02 | 20 | 10.10.20.22 |
| 123 | lab-cp03 | 20 | 10.10.20.23 |
| 131 | lab-wk01 | 20 | 10.10.20.31 |
| 132 | lab-wk02 | 20 | 10.10.20.32 |
| 141 | lab-edge01 | 30 | 10.10.30.21 |

### Common Phase 1 gotchas (you will hit at least one)

| Symptom | Cause | Fix |
|---|---|---|
| Provider panic: `interface conversion: interface {} is string, not float64` | You're running the **old Telmate** provider against Proxmox 8.x. ADR-0010-A migrated us to bpg. | `terraform init -upgrade` to pull bpg per `versions.tf`. If you're seeing this fresh, your `versions.tf` may still be stale. |
| `apply` errors with `does not have content type 'snippets'` | `local` storage missing snippets in its content list | `pvesm set local --content iso,vztmpl,backup,snippets`. § 5.0 covers this. |
| `apply` errors with `storage 'local-lvm' does not exist` | bpg's `initialization` block defaults its `datastore_id` to `local-lvm`, which doesn't exist on ZFS-only installs | Add `datastore_id = "local-zfs"` inside the `initialization` block in main.tf. § 5.2 has this. |
| Edge VM apply hangs ~15 min then warns "timeout while waiting for the QEMU agent" — cluster VMs are fine | dmz VM can't reach DNS or apt mirrors. Two stacked UniFi gotchas: (a) `Lab-DMZ → Gateway` had a `Block All` rule with the lowest ID, masking the per-service `DMZ DNS` allow underneath (rule-order issue, not missing rule); (b) `Lab-DMZ → External` similarly defaults to deny — needs explicit allows for tcp/80, tcp/443. cloud-init's apt fails on both DNS *and* HTTP. | Two-step: (1) In UniFi → Settings → Security → Zone-Based Firewall → click `Lab-DMZ → Gateway` cell → Reorder so `Block All` is the LAST custom rule (after `DMZ DNS`, `DMZ NTP`, `Allow mDNS`). (2) Click `Lab-DMZ → External` cell → add allow rules for tcp/80, tcp/443 (and tcp/udp 7844 for future cloudflared) → reorder so `Block All` is last. Then in main.tf use `dns { servers = each.value.bridge == "vmbr30" ? ["10.10.30.1", "1.1.1.1"] : ["10.10.10.1", "1.1.1.1"] }`. ARCH §3.3.2 + §3.3.3 + §3.3.4 document the full posture. |
| Apply succeeds but `ping <new-vm-ip>` fails for ~30-60 s after cloud-init "finishes" | UCG-Max's neighbor table hasn't seen the VM yet — return path can't resolve until the VM has emitted enough outbound traffic to populate the gateway's ARP cache. | Wait. Or `ssh root@10.10.10.10 "tcpdump -i tap<vmid>i0 -nn -c 20"` — once you see the VM transmitting, return-path pings start working. Not a fix needed, just transient. |
| UniFi Zone Matrix shows `Block All (N)` for a cell, but you know specific allow rules exist there | Rule-order issue. UniFi evaluates custom policies in ID order (lowest first); a `Block All` at the lowest ID short-circuits later allows. The matrix shows the *effective* outcome, not whether allows exist. | Click the cell to filter the policy list, then `Reorder` to push `Block All` below all specific allow rules. ARCH §3.3.4 documents this convention. |
| `terraform apply` fails with "Failed to load plugin schemas / Failed to read any lines from plugin's stdout / MachO architecture: CpuArm64 (current architecture: arm64)" — same provider that worked yesterday | macOS Gatekeeper re-quarantined the cached bpg/proxmox provider binary after an OS update. The binary is the right architecture but is silently blocked from executing. | `xattr -cr .terraform/` from `terraform/proxmox/` strips the quarantine flag. `scripts/tf.sh` now does this automatically on every Darwin invocation, so this should be self-healing going forward. If `xattr -cr` doesn't fix it, the binary needs the "Open Anyway" approval in System Settings → Privacy & Security. |
| `ping <dmz-vm>` from Mac Air works but `ssh <dmz-vm>` hangs at TCP handshake — tcpdump on the VM's tap shows SYN arriving and SYN-ACK going out, but Mac never receives the SYN-ACK | UniFi 9.x does not auto-create return-traffic allow rules for the `Lab-DMZ → Lab-Mgmt` zone-pair. ICMP echo replies sneak through (single-packet pseudo-stateful), but TCP three-way handshake fails because conntrack-based return packets are dropped. | UniFi → Settings → Security → Zone-Based Firewall → click `Lab-DMZ → Lab-Mgmt` cell → Create Policy: Allow, Lab-DMZ → Lab-Mgmt, Protocol All, **Match State = Established + Related** (uncheck New), reorder above the cell's `Block All`. Pattern documented in ADR-0013 and ARCH §3.3.5. |
| New dmz VM is unreachable from Mac Air for 30-90 s after `terraform apply` finishes, then starts working without you doing anything | UCG-Max's neighbor (ARP) cache still maps `10.10.30.21` to the **previous** VM's MAC. Stale entries age out or get refreshed when the new VM emits enough outbound traffic. | Wait. Or trigger refresh by pinging from the VM out to its gateway (forces bidirectional ARP). Not a fix needed; transient. |
| `apply` errors with `unable to read file '.../snippets/cucox-base.yaml'` | Snippet file missing on Proxmox host | Re-run § 5.0 step 2 to create the file. |
| Mac Air can ping `10.10.10.10` but not the VM IP | Phase 0 set up a VLAN-aware bridge instead of the three-bridge model in ADR-0012 | `bridge vlan show` should be EMPTY. If it has rows, you have the wrong network model — re-apply Phase 0 § 7.1 (Pattern B). |
| VM ends up on the wrong VLAN | Wrong `bridge` value in tfvars | Fix tfvars (`vmbr0` / `vmbr20` / `vmbr30`), re-apply. Don't try to add a `vlan_id` — we don't use it. |
| `apply` hangs at "Waiting for guest agent" | qemu-guest-agent install via cloud-init still running on first boot | Wait — bpg's default timeout is generous; install completes in ~30–45 s. If it actually times out, SSH in and check `journalctl -u cloud-init`. |
| All 6 VMs get `10.10.20.21` | Same machine-id baked into the cloud image | Run § 3.3 truncate (the `33` branch), re-template, re-clone. |
| VMs come up with no SSH keys | `vendor_data_file_id` content overrode user-data SSH key handling | Re-check `cucox-base.yaml` doesn't redefine `users:` — it should only have `packages` + `runcmd`. § 5.0 covers this. |
| Provider 401 errors | Token typo, wrong endpoint URL (must be `https://host:8006/`, not `https://host:8006/api2/json` for bpg) | Verify with `pveum user token list terraform@pve` and re-encrypt secrets if needed. |
| `virt-customize: Temporary failure resolving archive.ubuntu.com` | libguestfs appliance has flaky NAT'd DNS on a VLAN'd Proxmox host | Don't bake apt installs into the template; use cloud-init at first boot instead. § 3.3 explains. |
| Inside a cloned VM: `cloud-init: Temporary failure resolving archive.ubuntu.com` for ~5 min then exits | `qm set` (or Terraform) didn't pass DNS config; the VM has no resolver | Manual: add `--nameserver "10.10.10.1 1.1.1.1"` to `qm set`. Terraform: bpg's `initialization { dns { servers = [...] } }` (already in § 5.2). Re-clone the affected VM. |

### Rollback ladder (least to most destructive)

1. `qm rollback <vmid> phase1-base` — revert one VM.
2. `../../scripts/tf.sh destroy -target='proxmox_virtual_environment_vm.vm["lab-wk02"]'` then re-apply.
3. `../../scripts/tf.sh destroy` (all six). Template stays intact.
4. `zfs rollback rpool/data@phase1-pre-terraform`. Wipes everything Phase 1
   touched on the data pool. Console-only, no undo. (Post-migration this
   also takes out `tank/vmdata@phase1-pre-terraform` per ADR-0011.)

---

## Done when

- [ ] `tmpl-ubuntu-24-04` (VMID 9000) exists and is marked as a template.
- [ ] All six Phase 1 VMs are running, on their assigned VLANs, with the
      IPs in § 4.4.
- [ ] `ssh ubuntu@<each-ip> hostname` returns the matching name on the
      first try.
- [ ] Cluster VLAN VMs cannot reach Default LAN (firewall verified).
- [ ] All six VMs have a `phase1-base` snapshot.
- [ ] `terraform/proxmox/secrets.auto.tfvars.enc.yaml` is SOPS-encrypted in
      Git; no plaintext API token is anywhere in the repo or shell history.
- [ ] PR for `phase1-vm-bringup` merged to `main`.

Next: [`02-phase1-k3s-cluster.md`](./02-phase1-k3s-cluster.md) — k3s HA,
Cilium, MetalLB, ingress-nginx.
