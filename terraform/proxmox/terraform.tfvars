ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBIk74sdfHtr3s6zYJdZyhgmH9lhfDZYnhYjmI/dkMm9 cucox91@macbook-air"

vms = {
  "lab-cp01"   = { vmid = 121, cores = 4, memory = 8192, disk_gb = 40, bridge = "vmbr20", ip = "10.10.20.21/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-cp02"   = { vmid = 122, cores = 4, memory = 8192, disk_gb = 40, bridge = "vmbr20", ip = "10.10.20.22/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-cp03"   = { vmid = 123, cores = 4, memory = 8192, disk_gb = 40, bridge = "vmbr20", ip = "10.10.20.23/24", gw = "10.10.20.1", role = "k3s-server" }
  "lab-wk01"   = { vmid = 131, cores = 6, memory = 16384, disk_gb = 80, bridge = "vmbr20", ip = "10.10.20.31/24", gw = "10.10.20.1", role = "k3s-agent" }
  "lab-wk02"   = { vmid = 132, cores = 6, memory = 16384, disk_gb = 80, bridge = "vmbr20", ip = "10.10.20.32/24", gw = "10.10.20.1", role = "k3s-agent" }
  "lab-edge01" = { vmid = 141, cores = 2, memory = 4096, disk_gb = 20, bridge = "vmbr30", ip = "10.10.30.21/24", gw = "10.10.30.1", role = "edge" }
}