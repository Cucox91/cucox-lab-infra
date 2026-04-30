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
    size         = each.value.disk_gb # GB as a number, NOT "40G"
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  network_device {
    model  = "virtio"
    bridge = each.value.bridge # vmbr0 (mgmt) / vmbr20 (cluster) / vmbr30 (dmz) — ADR-0012
    # No vlan_id — the kernel VLAN sub-interface on the NIC tags egress for vmbr20/30
    # unconditionally. vmbr0 is native VLAN 10 via the lab-trunk port profile.
  }

  # Cloud-init configuration (replaces Telmate's flat ipconfig0/ciuser/sshkeys/etc).
  initialization {
    # Cloud-init drive storage. bpg defaults to "local-lvm" which doesn't exist
    # on a ZFS-only install — point at local-zfs explicitly.
    datastore_id = "local-zfs"

    user_account {
      username = "ubuntu"
      keys     = [trimspace(var.ssh_public_key)]
    }
    ip_config {
      ipv4 {
        address = each.value.ip # CIDR form: "10.10.20.21/24"
        gateway = each.value.gw
      }
    }
    # DNS resolver — per-VLAN, always the local gateway first:
    # - mgmt + cluster VMs use 10.10.10.1 (UCG-Max SVI on mgmt). cluster→mgmt
    #   on tcp/udp 53 is allowed because the resolver is reached at the
    #   gateway layer; the gateway then forwards upstream.
    # - dmz VMs (vmbr30) use 10.10.30.1 (UCG-Max SVI on dmz). They cannot
    #   reach 10.10.10.1 (ARCH §3.3 forbids dmz→mgmt) and cannot reach
    #   public DNS (ARCH §3.3 has no dmz→Internet allow), so the in-VLAN
    #   gateway forwarder is the only path. UCG-Max forwards to its upstream.
    # Public IPs (1.1.1.1) are kept as fallbacks but only mgmt/cluster will
    # ever reach them; for dmz they're inert (will time out cleanly if first
    # resolver becomes unreachable).
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
