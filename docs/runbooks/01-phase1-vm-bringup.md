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
| § 8.1 — Tooling | Telmate/proxmox provider; cloud-init for first-boot customization; SOPS for the Proxmox API token. |
| § 9 — Secrets | Proxmox API token & cloud-init password (if any) live in `terraform/proxmox/secrets.auto.tfvars.enc.yaml`, SOPS-encrypted. |
| ADR-0010 | Documents the Telmate/proxmox provider choice. |

What this runbook does **not** do: install k3s, install Cilium, install
anything cluster-shaped. Those are runbook 02.

---

## Prerequisites

- Runbook 00 (Phase 0) completed end-to-end. `lab-prox01` is reachable at
  `10.10.10.10` from the Mac Air on `CucoxLab-Mgmt`.
- Runbook 00a Steps 8–13 (the `tank` pool creation + Proxmox storage
  registration) completed. Verify on the Proxmox host:

  ```sh
  ssh root@10.10.10.10 'pvesm status'
  # expect rows for both `local-iso` and `tank-vmdata`, both `active`
  ```

  If `tank-vmdata` is missing, every `qm` and Terraform step in this runbook
  will fail with `storage 'tank-vmdata' does not exist`. Stop, finish 00a,
  return.

- ZFS pools `rpool` and `tank` are both healthy (`zpool status` is `ONLINE`,
  no errors). `tank/vmdata` is the default Proxmox storage for new VM disks.
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
pveum user add terraform@pve --comment "Terraform Telmate provider"

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
proxmox_api_url:        "https://10.10.10.10:8006/api2/json"
proxmox_api_token_id:   "terraform@pve!provider"
proxmox_api_token_secret: "REPLACE_ME_WITH_UUID_FROM_PVEUM_OUTPUT"
proxmox_tls_insecure:   true
EOF

# Encrypt in place.
sops --encrypt --in-place terraform/proxmox/secrets.auto.tfvars.enc.yaml

# Verify it actually encrypted (file should now contain `sops:` metadata).
head -5 terraform/proxmox/secrets.auto.tfvars.enc.yaml
```

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
  --efidisk0 tank-vmdata:0,format=raw,efitype=4m,pre-enrolled-keys=0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0,tag=10 \
  --serial0 socket --vga serial0 \
  --agent enabled=1 \
  --ostype l26

# Import the cloud image as a disk on `tank-vmdata`.
qm importdisk 9000 /rpool/iso/noble-server-cloudimg-amd64.img tank-vmdata

# Attach the imported disk as scsi0 (boot disk) with discard for ZFS TRIM.
qm set 9000 --scsi0 tank-vmdata:vm-9000-disk-1,discard=on,iothread=1,ssd=1

# Add a cloud-init drive on ide2 (Proxmox's default for cloud-init).
qm set 9000 --ide2 tank-vmdata:cloudinit

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
| `--agent enabled=1` | qemu-guest-agent (we'll install it in 3.3). Lets Proxmox query IPs, do graceful shutdowns. |
| `--net0 ... tag=10` | Template is on **mgmt** during build. Clones override the tag in cloud-init / Terraform. |

### 3.3 Pre-bake qemu-guest-agent into the image (once)

The cloud image doesn't include the guest agent. We could install it on
every clone via cloud-init, but baking it once saves time.

```sh
# Install libguestfs tools on the Proxmox host (once).
apt -y install libguestfs-tools

# Discover the actual disk path. With `tank-vmdata` (ZFS) it's a zvol;
# with directory-backed storage it would be a qcow2 file.
DISK=$(qm config 9000 | awk -F'[ ,]' '/^scsi0:/ {print $2}')
echo "scsi0 maps to: $DISK"
# tank-vmdata:vm-9000-disk-1   →   /dev/zvol/tank/vmdata/vm-9000-disk-1
# local:9000/vm-9000-disk-1.qcow2 →  /var/lib/vz/images/9000/vm-9000-disk-1.qcow2

# Stop the VM (must be off for libguestfs to lock the device).
qm stop 9000 2>/dev/null || true

# For tank-vmdata (ZFS zvol — the path you'll see in this lab):
virt-customize -a /dev/zvol/tank/vmdata/vm-9000-disk-1 \
  --install qemu-guest-agent \
  --truncate /etc/machine-id

# (Fallback for directory-backed storage — not used here, kept for reference)
# virt-customize -a /var/lib/vz/images/9000/vm-9000-disk-1.qcow2 \
#   --install qemu-guest-agent \
#   --truncate /etc/machine-id
```

`--truncate /etc/machine-id` is critical. Without it, every clone shares
the same machine-id and DHCP / systemd-networkd will hand out the same
lease. (We use static IPs anyway, but the principle stands.)

> **If `virt-customize` fails with "Permission denied" on the zvol:**
> ensure the VM is fully stopped (`qm status 9000` shows `stopped`) and
> that no other process holds the device (`lsof /dev/zvol/tank/vmdata/vm-9000-disk-1`
> should be empty). If `qm template 9000` has already been run, the zvol
> is read-only — undo with `zfs set readonly=off tank/vmdata/vm-9000-disk-1`,
> customize, then re-template.

### 3.4 Convert to a template

```sh
qm template 9000
```

After this, VMID 9000 is read-only and clones become near-instant
(linked-clone disk semantics on ZFS).

### 3.5 Sanity-clone (one-shot, throwaway)

Before introducing Terraform, prove the template works manually:

```sh
qm clone 9000 999 --name probe-clone --full
qm set 999 --ipconfig0 ip=10.10.10.99/24,gw=10.10.10.1\
           --ciuser ubuntu \
           --sshkeys /root/.ssh/authorized_keys \
           --net0 virtio,bridge=vmbr0,tag=10
qm start 999

# Watch it come up.
qm terminal 999     # exits with Ctrl-O Ctrl-X

# From the Mac Air, once it has an IP:
ssh ubuntu@10.10.10.99 'uname -a; systemctl is-active qemu-guest-agent'
```

Expected: SSH works on first try, guest agent is `active`. If it doesn't,
**fix the template, not the clone**. Then:

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
zfs snapshot tank/vmdata@phase1-pre-terraform
zfs snapshot rpool/data@phase1-pre-terraform 2>/dev/null || true
zfs list -t snapshot
```

To roll back later (from console only — destructive):

```sh
zfs rollback tank/vmdata@phase1-pre-terraform
```

---

## Step 5 — Define the six VMs in Terraform

### 5.1 Provider + variable plumbing

Create `terraform/proxmox/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "~> 2.9.14"   # pin per ADR-0010
    }
  }
}

provider "proxmox" {
  pm_api_url          = var.proxmox_api_url
  pm_api_token_id     = var.proxmox_api_token_id
  pm_api_token_secret = var.proxmox_api_token_secret
  pm_tls_insecure     = var.proxmox_tls_insecure
  pm_parallel         = 2     # Telmate is happiest with low parallelism
}
```

Create `terraform/proxmox/variables.tf`:

```hcl
variable "proxmox_api_url" {
  type = string
}

variable "proxmox_api_token_id" {
  type = string
}

variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_tls_insecure" {
  type    = bool
  default = true
}

variable "proxmox_node" {
  type    = string
  default = "lab-prox01"
}

variable "template_name" {
  type    = string
  default = "tmpl-ubuntu-24-04"
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
    vlan    = number
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
  "lab-cp01"   = { vmid = 121, cores = 4, memory =  8192, disk_gb = 40, vlan = 20, ip = "10.10.20.21/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-cp02"   = { vmid = 122, cores = 4, memory =  8192, disk_gb = 40, vlan = 20, ip = "10.10.20.22/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-cp03"   = { vmid = 123, cores = 4, memory =  8192, disk_gb = 40, vlan = 20, ip = "10.10.20.23/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-wk01"   = { vmid = 131, cores = 6, memory = 16384, disk_gb = 80, vlan = 20, ip = "10.10.20.31/24", gw = "10.10.20.1", role = "k3s-agent"  }
  "lab-wk02"   = { vmid = 132, cores = 6, memory = 16384, disk_gb = 80, vlan = 20, ip = "10.10.20.32/24", gw = "10.10.20.1", role = "k3s-agent"  }
  "lab-edge01" = { vmid = 141, cores = 2, memory =  4096, disk_gb = 20, vlan = 30, ip = "10.10.30.21/24", gw = "10.10.30.1", role = "edge"      }
}
```

VMID assignments: `1<role-digit><instance>`. CP=2x, WK=3x, EDGE=4x. Stable
mental model, doesn't collide with the template at `9000`.

### 5.2 The VM resource

Create `terraform/proxmox/main.tf`:

```hcl
resource "proxmox_vm_qemu" "vm" {
  for_each = var.vms

  name        = each.key
  vmid        = each.value.vmid
  target_node = var.proxmox_node
  clone       = var.template_name
  full_clone  = true        # full clone — predictable I/O, easier to reason about
  os_type     = "cloud-init"
  agent       = 1
  cpu         = "host"
  cores       = each.value.cores
  sockets     = 1
  memory      = each.value.memory
  scsihw      = "virtio-scsi-single"
  bootdisk    = "scsi0"

  disk {
    type     = "scsi"
    storage  = "tank-vmdata"
    size     = "${each.value.disk_gb}G"
    discard  = "on"
    iothread = 1
    ssd      = 1
  }

  network {
    model  = "virtio"
    bridge = "vmbr0"
    tag    = each.value.vlan
  }

  ipconfig0  = "ip=${each.value.ip},gw=${each.value.gw}"
  ciuser     = "ubuntu"
  sshkeys    = var.ssh_public_key
  nameserver = "10.10.10.1 1.1.1.1"
  searchdomain = "lab.cucox.local"

  # Keep the cloud-init disk consistent across re-applies.
  lifecycle {
    ignore_changes = [
      network,        # Telmate sometimes re-renders MAC; ignore to avoid churn
      disk[0].size,   # in-place grows are intentional, not drift
    ]
  }

  tags = "phase1;${each.value.role}"
}

output "vm_ips" {
  value = { for k, v in var.vms : k => v.ip }
}
```

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
`versions.tf`. Telmate publishes new patches roughly every 2–3 months.

### 6.2 Plan with secrets injected at runtime

We never write the plaintext token to disk. Use SOPS at apply time:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/terraform/proxmox"

# Decrypt to a tmpfs path that gets cleaned up by the shell on exit.
SECRETS=$(mktemp -t pmsecrets.XXXX.json)
trap "rm -f $SECRETS" EXIT
sops --decrypt secrets.auto.tfvars.enc.yaml | yq -o=json > "$SECRETS"

# Pass each var via -var. The token secret is short-lived in env.
terraform plan \
  -var "proxmox_api_url=$(jq -r .proxmox_api_url $SECRETS)" \
  -var "proxmox_api_token_id=$(jq -r .proxmox_api_token_id $SECRETS)" \
  -var "proxmox_api_token_secret=$(jq -r .proxmox_api_token_secret $SECRETS)" \
  -var "proxmox_tls_insecure=$(jq -r .proxmox_tls_insecure $SECRETS)"
```

Wrap that in `scripts/tfplan.sh` once it works — repeating the
`-var` block for `apply` and `destroy` gets old fast.

The first plan should show **6 resources to add**, and nothing else.

### 6.3 Apply

```sh
terraform apply ...   # same -var args as plan
```

Telmate creates VMs serially even with `pm_parallel=2` because cloud-init
disk attachments serialize at the storage layer. Expect ~20–30 seconds per
VM, ~3 minutes total.

> **If apply hangs at "Waiting for the VM to start":** the most common
> cause is that cloud-init couldn't reach the VLAN's gateway. Check on the
> Proxmox host: `qm config <vmid> | grep -E 'net0|ipconfig0'` should show
> `tag=20` (or 30) and the right IP. If the tag is missing, the bridge
> isn't VLAN-aware — go re-read Phase 0 § 7.1.

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
- Telmate/proxmox provider (see ADR-0010)
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

### Common Telmate gotchas (you will hit at least one)

| Symptom | Cause | Fix |
|---|---|---|
| `apply` hangs forever on first VM | Cloud-init disk on wrong bus | `qm set <vmid> --ide2 tank-vmdata:cloudinit`, retry. |
| All 6 VMs get `10.10.20.21` | Same machine-id (`/etc/machine-id` not truncated in template) | Re-run Step 3.3, recreate template, re-clone. |
| Provider 401 errors | Token typo or `privsep=1` mis-set | `pveum user token list terraform@pve` to verify. |
| Plan shows constant drift on `network[0].macaddr` | Telmate regenerates MACs | Already covered by `ignore_changes = [network]` in main.tf. |
| New disk size doesn't apply | `disk[0].size` ignored due to lifecycle rule | Manually `qm resize` and update tfvars to keep state honest. |

### Rollback ladder (least to most destructive)

1. `qm rollback <vmid> phase1-base` — revert one VM.
2. `terraform destroy -target=proxmox_vm_qemu.vm[\"lab-wk02\"]` then re-apply.
3. `terraform destroy` (all six). Template stays intact.
4. `zfs rollback tank/vmdata@phase1-pre-terraform`. Wipes everything Phase 1
   touched on the data pool. Console-only, no undo.

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
