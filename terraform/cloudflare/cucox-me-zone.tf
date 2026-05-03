# cucox.me Cloudflare zone — created out-of-band in runbook 03 § Step 2.0
# via the dashboard "Add a Site" wizard, stopped before the "check
# nameservers" step. Sits in Pending Nameserver Update state until
# runbook 05 § Step 5 changes nameservers at GoDaddy.
#
# Imported into Terraform state by the declarative import block below.
# Creating from scratch would error ("zone already exists"); the import
# pattern matches what tunnel.tf does for the cucox-lab-prod tunnel.
#
# See runbook 05 § Step 3.1 for the full rationale and verification flow.

import {
  to = cloudflare_zone.cucox_me
  id = var.cucox_me_zone_id
}

resource "cloudflare_zone" "cucox_me" {
  account_id = var.cloudflare_account_id
  zone       = "cucox.me"
  plan       = "free"

  # paused / jump_start / type can drift from Cloudflare's defaults
  # across UI actions; ignore so subsequent plans don't propose churn.
  # If a plan ever proposes changes to one of these, decide deliberately
  # rather than auto-applying.
  lifecycle {
    ignore_changes = [paused, jump_start, type]
  }
}

output "cucox_me_zone_id" {
  description = "Zone ID for cucox.me. Used by cucox-me-records.tf."
  value       = cloudflare_zone.cucox_me.id
}
