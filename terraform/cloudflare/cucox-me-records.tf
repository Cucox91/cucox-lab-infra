# cucox.me DNS records — Tunnel-backed hostnames (apex + www).
#
# Both CNAMEs target the cucox-lab-prod tunnel via the provider's
# built-in `cname` attribute on the tunnel resource (equivalent to
# "<TUNNEL_UUID>.cfargotunnel.com" but typed and dependency-tracked).
#
# Both are orange-clouded (proxied=true), TTL=1 means Auto (Cloudflare
# requires Auto when proxied is true). The cloudflared ingress block on
# lab-edge01 dispatches by Host header per ADR-0014.
#
# What this file does NOT manage (intentionally):
#   - TXT @ "_gaiibn..."         — App Service domain validation, deleted in Step 7
#   - TXT asuid                  — App Service ownership token,    deleted in Step 7
#   - CNAME _domainconnect       — GoDaddy proprietary,             dropped in Step 2
# Importing each individually for a few weeks of life is unnecessary
# churn. They live in Cloudflare's auto-imported state until runbook 05
# § Step 7 cleans them up.

resource "cloudflare_record" "cucox_me_apex" {
  zone_id = cloudflare_zone.cucox_me.id
  name    = "@"
  type    = "CNAME"
  content = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.cname
  proxied = true
  ttl     = 1
  comment = "managed-by-terraform; tunnel: cucox-lab-prod"
}

resource "cloudflare_record" "cucox_me_www" {
  zone_id = cloudflare_zone.cucox_me.id
  name    = "www"
  type    = "CNAME"
  content = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.cname
  proxied = true
  ttl     = 1
  comment = "managed-by-terraform; tunnel: cucox-lab-prod"
}
