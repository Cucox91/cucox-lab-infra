# Runbook 05a — Zone-Specific Notes: `cucox.me` (pre-migration state)

> **Purpose:** Capture the pre-migration DNS state for `cucox.me`,
> identify what each record does, and define the record-by-record
> migration plan that runbook 05 will execute. This file is read
> alongside [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
> when migrating this specific zone.
>
> **Pattern:** copy-and-adapt this file for each subsequent zone
> (`exycle.com`, `cucoxcorp.com`) when their migration begins. Naming
> convention: `05a-zone-<zone>-pre-migration.md`.
>
> **Source of truth:** GoDaddy zone export captured 2026-05-01 at
> `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-2026-05-01.zone`
> (outside the repo by design — this is a rollback reference, not
> shared infrastructure).

---

## Record inventory (snapshot of GoDaddy state)

Seven content records on `cucox.me` at the time of export (ignoring SOA):

| # | Name | Type | TTL | Value | Function |
|---|---|---|---|---|---|
| 1 | `@` | A | 600 | `20.119.128.24` | Apex → Azure (Static Web Apps origin IP) |
| 2 | `@` | NS | 3600 | `ns57.domaincontrol.com.` | GoDaddy authoritative NS |
| 3 | `@` | NS | 3600 | `ns58.domaincontrol.com.` | GoDaddy authoritative NS |
| 4 | `@` | TXT | 3600 | `"_gaiibnhsztllqp7ekh2t77wveg13s4t"` | Azure domain validation (likely Static Web Apps) |
| 5 | `asuid` | TXT | 3600 | `"AB0A99E134…0AC2D964C"` | Azure App Service custom-domain ownership token (`asuid` is Azure's canonical prefix) |
| 6 | `www` | CNAME | 1800 | `lemon-mud-0d596dd0f.6.azurestaticapps.net.` | www → Azure Static Web App (production) |
| 7 | `_domainconnect` | CNAME | 3600 | `_domainconnect.gd.domaincontrol.com.` | GoDaddy proprietary "Domain Connect" auto-config — meaningless after NS leaves GoDaddy |

What is **not** present (relevant to migration risk):

- **No MX records** → no email ever delivered to addresses on this
  domain. Email-disruption risk during cutover is **zero**.
- **No DMARC record** → no email-spoofing policy. Combined with no MX,
  consistent with "this domain does not do email at all".
- **No SPF record** → as above.
- **No CAA records** → no constraints on which CAs may issue TLS certs.
  Cloudflare's edge cert (Universal SSL) issues without obstacle after
  migration.
- **No SRV records.**
- **No subdomain delegations** (no NS at non-apex labels).

## What `asuid` tells you

The presence of an `asuid.cucox.me` TXT record means an **Azure App
Service** resource was at some point bound to `cucox.me` for custom-
domain validation. That's distinct from the Static Web App that the
apex A and `www` CNAME currently point at. Two possibilities:

- **Stale leftover** — an older Azure App Service was bound to this
  domain in the past, and the verification TXT was never cleaned up.
- **Active App Service** — still bound, perhaps for a path or subdomain
  not surfaced in the inventory above.

**Action:** before runbook 05 § Step 7 (old-host teardown), log into
the Azure portal and resolve which case it is. If stale, the `asuid`
TXT can be deleted post-cutover. If active, either bring that App
Service into the cluster migration scope OR keep the TXT until the
App Service itself is decommissioned. Either way, **preserve the TXT
through the runbook 05 cutover window** — Azure may revalidate during
the 48-hour overlap.

## Migration plan (record-by-record)

Each record's lifecycle through the four migration phases:

| Record | Today (GoDaddy) | After Cloudflare zone import (Pending) | After runbook 05 § Step 3 (Tunnel CNAMEs) | After runbook 05 § Step 7 (Azure teardown) |
|---|---|---|---|---|
| Apex A/CNAME | A `→ 20.119.128.24` | A `→ 20.119.128.24` (grey, unchanged) | **CNAME `→ <UUID>.cfargotunnel.com`** (orange) | unchanged |
| `www` CNAME | `→ ...azurestaticapps.net` | `→ ...azurestaticapps.net` (grey, unchanged) | **CNAME `→ <UUID>.cfargotunnel.com`** (orange) | unchanged |
| TXT `@` | `_gaiibn...` | preserved verbatim | preserved | **delete** (Azure validation no longer needed) |
| TXT `asuid` | `AB0A99...` | preserved verbatim | preserved | **delete** (App Service validation no longer needed) |
| CNAME `_domainconnect` | `→ ...gd.domaincontrol.com.` | optional — Cloudflare may not auto-import | dropped | dropped |
| NS | `ns57/58.domaincontrol.com.` | unchanged (still GoDaddy) | unchanged | replaced at registrar by Cloudflare NS in runbook 05 § Step 5 |

### Records that absolutely must be preserved verbatim

Two records that runbook 05 § Step 2's "verify import draft" phase
must check character-for-character against the GoDaddy export:

1. **TXT `@` `"_gaiibnhsztllqp7ekh2t77wveg13s4t"`** — Azure validation.
2. **TXT `asuid` `"AB0A99E134D176B861F437FB8BB691DA2EBEEEF5CF4D342B0B6E6810AC2D964C"`** — Azure App Service validation.

If either is missing or modified in Cloudflare's auto-import, **add it
manually before the wizard's Confirm step** with the exact value above.

### Records that get replaced (not preserved)

- **Apex A `20.119.128.24`** → CNAME to `<UUID>.cfargotunnel.com` (orange-clouded).
- **`www` CNAME `lemon-mud-0d596dd0f.6.azurestaticapps.net.`** → CNAME to `<UUID>.cfargotunnel.com` (orange-clouded).

Both replacements happen in runbook 05 § Step 3 via Terraform. The old
Azure values must remain reachable until the 48-hour gate in runbook 05
§ Step 7 — the old DNS path is the safety net during NS propagation.

### Records that can be dropped

- **CNAME `_domainconnect → _domainconnect.gd.domaincontrol.com.`** —
  GoDaddy-proprietary, no function on a non-GoDaddy nameserver. Can be
  omitted from Cloudflare's zone entirely. Not load-bearing for any
  active service.

## Migration risk profile

| Concern | Status | Notes |
|---|---|---|
| Email disruption | **None possible** | No MX, no DMARC, no SPF — there is no email infrastructure to break. |
| TLS cert issuance blocked | **None** | No CAA records — Cloudflare Universal SSL issues without obstacle. |
| SaaS ownership re-validation | **Two TXTs to preserve** | Azure verification + Azure App Service `asuid`. Preserve through the 48-hour overlap window in runbook 05 § Step 7. |
| Active services to migrate | **One** | Azure Static Web App serves both apex and www. After cutover, both flow into the cluster via the Tunnel. Azure App Service status (active or stale) needs Azure-portal investigation before § Step 7. |
| Subdomain breakage | **None known** | No subdomains beyond `www` are present. If undocumented subdomains exist (e.g. `api.cucox.me` not in the GoDaddy export), they would silently break at NS cutover. |

## Pre-cutover actions (informational, not required)

These are optional hardening steps that can be done at GoDaddy **before**
runbook 05 § Step 5 (NS change) for a smoother cutover:

- **Drop TTLs ~24 hours before cutover.** Edit each record at GoDaddy and
  set TTL to 300s. Doesn't change current behavior; only changes how
  long stale resolvers cache the *old* records during the NS flip. With
  current TTLs of 600–3600s, propagation tail is at most ~1 hour; with
  300s TTLs, ~5 minutes.

- **Confirm Azure App Service status.** Before § Step 7 fires, log into
  the Azure portal and identify which App Service the `asuid` TXT
  validates. Decide whether it stays (and the TXT stays with it) or
  goes (and the TXT goes with it).

## Open questions to resolve before runbook 05 § Step 7

- [ ] Which Azure App Service does `asuid.cucox.me` validate? Active or
      stale?
- [ ] Is the apex A (`20.119.128.24`) still pointing at the same Azure
      Static Web App as `www`, or at a separate Azure resource?
- [ ] Are there any undocumented subdomains in use (test environments,
      legacy apps) that the GoDaddy export doesn't show but a former
      service might still resolve via cached records?

## Related files

- GoDaddy export (rollback baseline): `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-2026-05-01.zone`
- General migration procedure: [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
- Tunnel infrastructure (consumed by this migration): [`03-phase2-cloudflared-tunnel.md`](./03-phase2-cloudflared-tunnel.md)
- Architecture reference: ARCH § 6.3 (per-domain ingress dispatch)
