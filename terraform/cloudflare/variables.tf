# Variables for the cloudflare/ Terraform module.
#
# All three are populated via TF_VAR_* environment variables — none should
# ever land on disk in plaintext. The token decrypts on demand from
# secrets.enc.yaml. See runbook 03 § 8 for the standard invocation.

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Scoped Cloudflare API token. Permissions: Account/Cloudflare Tunnel:Edit, Zone/DNS:Edit (all zones), Zone/Zone:Read (all zones). Rotation cadence 90 days; see runbook 03 § 1."
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID. Visible in any account-scoped dashboard URL (dash.cloudflare.com/<ACCOUNT_ID>/...) or via /accounts API endpoint."
}

variable "tunnel_uuid" {
  type        = string
  description = "UUID of the cucox-lab-prod Cloudflare Tunnel. Created via 'cloudflared tunnel create' (runbook 03 § 2.2). Imported into this module — not created by Terraform."
}

variable "tunnel_secret" {
  type        = string
  sensitive   = true
  description = "Base64-encoded tunnel secret. Cloudflare provider v4.40+ requires this on the tunnel resource even when the tunnel was created out-of-band. Extracted from the SOPS-sealed creds JSON via: sops --decrypt ../../ansible/group_vars/lab_edge/tunnel-creds.enc.json | jq -r .TunnelSecret. Never persists outside Terraform state (gitignored)."
}
