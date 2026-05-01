# cucox-lab-prod tunnel — created out-of-band via `cloudflared tunnel create`
# in runbook 03 § 2.2, imported into Terraform state in runbook 03 § 8.2.
#
# config_src = "local" indicates the tunnel's ingress configuration lives in
# /etc/cloudflared/config.yaml on lab-edge01 (locally-managed pattern), not in
# the Cloudflare dashboard. Per runbook 03 § Step 0 rationale.

# Declarative import (Terraform 1.5+). The first `terraform plan/apply` after
# this block lands will perform the import. Subsequent plans see the resource
# already in state and skip the directive (no-op). The block stays in the repo
# as documentation of what was imported and as a re-import path if state is
# ever lost (`terraform state rm` followed by re-apply replays the import).
import {
  to = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod
  id = "${var.cloudflare_account_id}/${var.tunnel_uuid}"
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "cucox_lab_prod" {
  account_id = var.cloudflare_account_id
  name       = "cucox-lab-prod"
  secret     = var.tunnel_secret
  config_src = "local"

  # Lifecycle ignores:
  #
  # secret      — the tunnel's auth credential. Rotating it here would
  #               invalidate /etc/cloudflared/creds.json on lab-edge01 and the
  #               daemon would lose its connections. Secret rotation is a
  #               deliberate, out-of-band operation (delete tunnel → recreate
  #               → re-seal new creds), not something Terraform should ever
  #               attempt as part of a routine apply.
  #
  # config_src  — Cloudflare's API does not return this field on read, so
  #               Terraform sees (null) → "local" after import and marks it
  #               ForceNew. Without this ignore, every plan would propose a
  #               destroy+recreate of the tunnel, invalidating creds.json
  #               on lab-edge01. The field is kept in the resource block as
  #               documentation of the locally-managed pattern (per runbook 03
  #               § Step 0 rationale) — it's just not actionable drift.
  lifecycle {
    ignore_changes = [secret, config_src]
  }
}

output "tunnel_id" {
  description = "UUID of the cucox-lab-prod tunnel. Used by runbook 05 to construct CNAMEs (tunnel_id.cfargotunnel.com)."
  value       = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.id
}

output "tunnel_cname" {
  description = "The CNAME target for any hostname routed through this tunnel."
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.id}.cfargotunnel.com"
}
