terraform {
  required_version = ">= 1.7"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66" # pin per ADR-0010-A (replaces Telmate)
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token # joined string: "<id>=<secret>"
  insecure  = var.proxmox_tls_insecure
}
