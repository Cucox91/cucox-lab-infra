# Terraform provider pin for Cloudflare resources (Tunnel + DNS).
# See runbook 03 § 8 for setup; runbook 05 § Step 3 will add cloudflare_record
# resources per migrated zone.

terraform {
  required_version = ">= 1.7"

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # Pinning to v4.x for now. v5 is a major rewrite using the new
      # internal API SDK; migration will be tracked in a future ADR
      # if/when the v4 line is deprecated.
      version = "~> 4.40"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
