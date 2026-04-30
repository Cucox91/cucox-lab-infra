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
    bridge  = string # one of vmbr0 / vmbr20 / vmbr30 — see ADR-0012
    ip      = string # e.g. "10.10.20.21/24"
    gw      = string
    role    = string # informational tag only
  }))
}
