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
> **Source of truth (zone export):** GoDaddy zone export captured
> 2026-05-01 at
> `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-2026-05-01.zone`
> (outside the repo by design — this is a rollback reference, not
> shared infrastructure).
>
> **Source of truth (Azure resources):** Azure portal screenshots
> reviewed 2026-05-02 against subscription `Single Pages`
> (`e09a5cd0-509d-4766-bd6b-4938325c07dd`), tenant `Cucox Corp.`,
> resource group `Single_Pages`. Findings reverse this file's
> earlier (2026-05-01) record-attribution guesses.

---

## Record inventory (snapshot of GoDaddy state)

Seven content records on `cucox.me` at the time of export (ignoring SOA):

| # | Name | Type | TTL | Value | Function (corrected 2026-05-02) |
|---|---|---|---|---|---|
| 1 | `@` | A | 600 | `20.119.128.24` | Apex → **Azure App Service Web App `CucoxResumeApp`** Virtual IP. Confirmed by Azure portal Networking panel. |
| 2 | `@` | NS | 3600 | `ns57.domaincontrol.com.` | GoDaddy authoritative NS |
| 3 | `@` | NS | 3600 | `ns58.domaincontrol.com.` | GoDaddy authoritative NS |
| 4 | `@` | TXT | 3600 | `"_gaiibnhsztllqp7ekh2t77wveg13s4t"` | **Azure App Service** domain-validation TXT for the `cucox.me` custom-domain binding on `CucoxResumeApp`. (Earlier guess: "Static Web Apps" — wrong; SWA isn't in this subscription.) |
| 5 | `asuid` | TXT | 3600 | `"AB0A99E134…0AC2D964C"` | **Azure App Service** custom-domain ownership token, paired with the same `cucox.me` binding on `CucoxResumeApp`. The `asuid` prefix is App Service's. |
| 6 | `www` | CNAME | 1800 | `lemon-mud-0d596dd0f.6.azurestaticapps.net.` | **Orphaned** — points at an Azure Static Web App that does NOT exist in subscription `Single Pages` (verified by `az staticwebapp list` returning `[]`). May still exist in `Exycle App Subscription` or `My DevOps`; if not, `www.cucox.me` has been silently 404-ing for some time. |
| 7 | `_domainconnect` | CNAME | 3600 | `_domainconnect.gd.domaincontrol.com.` | GoDaddy proprietary "Domain Connect" auto-config — meaningless after NS leaves GoDaddy. |

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

---

## What we now know about the Azure side (corrected 2026-05-02)

Direct Azure portal review confirms a single live App Service Web App
serves `cucox.me`:

| Field | Value |
|---|---|
| Resource | `CucoxResumeApp` (App Service Web App, kind `app,linux`) |
| Subscription | `Single Pages` (`e09a5cd0-509d-4766-bd6b-4938325c07dd`) |
| Resource group | `Single_Pages` |
| Region | East US 2 |
| App Service Plan | `Node-SinglePages-Cucox` (Basic B1, 1 instance) |
| Runtime stack | Node 22 LTS, Linux, publishing model `Code` |
| Default hostname | `cucoxresumeapp.azurewebsites.net` |
| **Custom domain bound** | `cucox.me` (apex only — `www.cucox.me` is NOT bound here) |
| Virtual IP address | `20.119.128.24` (matches the apex A record) |
| App Insights | enabled, name `CucoxResumeApp`, region East US 2 |
| Deployment provider (portal) | None — but `.github/workflows/azure-deploy.yml` exists in the source repo and uses `azure/webapps-deploy@v2` with `secrets.AZURE_WEBAPP_PUBLISH_PROFILE`. Externally-authored workflow; portal doesn't surface it. |
| Last deploy | 2026-04-18, Successful |
| VNet integration | `vnet-utfgqvav/subnet-lnmfhnhd` (outbound; not surfaced as load-bearing for this app — likely vestigial) |

**Azure Static Web Apps in `Single Pages` subscription:** none
(verified by `az staticwebapp list` on 2026-05-02 returning `[]`).

**Azure Static Web Apps in other subscriptions:** unverified at time of
this writing. The `www` CNAME's target (`lemon-mud-0d596dd0f.6.azurestaticapps.net.`)
implies a Static Web App existed at some point. Either it was deleted,
or it lives in `Exycle App Subscription` or `My DevOps`. Either way,
runbook 05's Step 3.1 replaces the `www` CNAME with a Tunnel CNAME,
and the orphan target becomes irrelevant after cutover.

---

## App-side environment variables (current Azure config)

Captured from CucoxResumeApp → Settings → Environment variables on
2026-05-02:

| Name | Value | Read by |
|---|---|---|
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | (sensitive) | App Insights agent — vestigial after cluster migration. |
| `ApplicationInsightsAgent_EXTENSION_VERSION` | `~3` | App Insights auto-instrumentation. Vestigial. |
| `BACKEND_URL` | `https://cucoxresumeapp.azurewebsites.net` | **Nothing in the running code** — grep across `server/src/` returns no `process.env.BACKEND_URL` reference. The frontend uses `import.meta.env.VITE_BACKEND_URL` (build-time only). The Azure-side `BACKEND_URL` is unused and will not be set in the cluster Deployment. |
| `CLIENT_URL` | `https://cucoxresumeapp.azurewebsites.net` | Express CORS origin allowlist (`server/src/app.ts:20`). Cluster value: `https://cucox.me`. |
| `JWT_SECRET` | (sensitive) | JWT signing in the auth controller (`server/src/controllers/authController.ts:7`). Cluster: re-generated and SOPS-sealed. |
| `MONGO_URI` | (sensitive — mongodb+srv connection string with credentials) | Mongoose connect (`server/src/app.ts:35`). Cluster: SOPS-sealed; Atlas IP allowlist must include cluster egress IP before cutover. |
| `PORT` | `5001` | Server listen port (`server/src/server.ts:5`). Cluster value: `5001`. Service `targetPort: 5001`. |
| `SEED_DATA` | (not currently set) | One-shot demo-data seeder (`server/src/app.ts:47`). **Cluster Deployment must NOT set this** — would re-seed on every pod restart. Run as separate Job if needed. |
| `XDT_MicrosoftApplicationInsights_Mode` | `default` | App Insights config flag. Vestigial. |

---

## Frontend env handling — same-origin via relative URLs

`client/src/apis/axiosInstance.ts:4`:

```ts
baseURL: import.meta.env.VITE_BACKEND_URL || ""
```

`VITE_BACKEND_URL` is a **Vite build-time** variable. The GH Actions
workflow's `vite build` step does not set it, so the production frontend
bundle is built with `baseURL = ""` → axios uses relative paths →
same-origin requests. Net consequence for migration:

- The cluster Dockerfile's client-build stage does NOT set
  `VITE_BACKEND_URL`. Same `baseURL = ""`, same relative URLs.
- Once the SPA loads from `https://cucox.me/`, all `/api/...` calls go
  to the same Express server in the same pod. No CORS, no rebuild
  required.

---

## Migration plan (record-by-record, corrected 2026-05-02)

Each record's lifecycle through the four migration phases:

| Record | Today (GoDaddy) | After Cloudflare zone import (Pending) | After runbook 05 § Step 3 (Tunnel CNAMEs) | After runbook 05 § Step 7 (App Service teardown) |
|---|---|---|---|---|
| Apex A/CNAME | A `→ 20.119.128.24` (CucoxResumeApp VIP) | A `→ 20.119.128.24` (grey, unchanged) | **CNAME `→ <UUID>.cfargotunnel.com`** (orange, via Terraform) | unchanged |
| `www` CNAME | `→ ...azurestaticapps.net` (orphaned target) | `→ ...azurestaticapps.net` (grey, unchanged — orphan persists) | **CNAME `→ <UUID>.cfargotunnel.com`** (orange, via Terraform) | unchanged |
| TXT `@` `_gaiibn...` | App Service validation | preserved verbatim | preserved | **delete** (App Service is gone — TXT is meaningless) |
| TXT `asuid` `AB0A99...` | App Service validation | preserved verbatim | preserved | **delete** (App Service is gone) |
| CNAME `_domainconnect` | `→ ...gd.domaincontrol.com.` | optional — Cloudflare may not auto-import | dropped | dropped |
| NS | `ns57/58.domaincontrol.com.` | unchanged (still GoDaddy) | unchanged | replaced at registrar by Cloudflare NS in runbook 05 § Step 5 |

### Records that absolutely must be preserved verbatim through Step 5

Two records that runbook 05 § Step 2's "verify import draft" phase
must check character-for-character against the GoDaddy export, and
that runbook 05 § Step 7 deletes only after the App Service deletion:

1. **TXT `@` `"_gaiibnhsztllqp7ekh2t77wveg13s4t"`** — App Service
   validation for the `cucox.me` custom-domain binding on
   CucoxResumeApp.
2. **TXT `asuid` `"AB0A99E134D176B861F437FB8BB691DA2EBEEEF5CF4D342B0B6E6810AC2D964C"`** —
   App Service custom-domain ownership token for the same binding.

If either is missing or modified in Cloudflare's auto-import, **add it
manually before the wizard's Confirm step** with the exact value above.
Azure may revalidate during the 48-hour overlap window and a missing
TXT would unbind the custom domain server-side.

### Records that get replaced (not preserved)

- **Apex A `20.119.128.24` (CucoxResumeApp VIP)** → CNAME to
  `<UUID>.cfargotunnel.com` (orange-clouded), in runbook 05 § Step 3.1.
- **`www` CNAME `lemon-mud-0d596dd0f.6.azurestaticapps.net.`** → CNAME
  to `<UUID>.cfargotunnel.com` (orange-clouded), in runbook 05 § Step 3.1.

The old Azure App Service IP must remain reachable until the 48-hour
gate in runbook 05 § Step 7 — the old DNS path is the safety net during
NS propagation.

### Records that can be dropped

- **CNAME `_domainconnect → _domainconnect.gd.domaincontrol.com.`** —
  GoDaddy-proprietary, no function on a non-GoDaddy nameserver. Can be
  omitted from Cloudflare's zone entirely. Not load-bearing for any
  active service.

---

## Migration risk profile (corrected 2026-05-02)

| Concern | Status | Notes |
|---|---|---|
| Email disruption | **None possible** | No MX, no DMARC, no SPF — there is no email infrastructure to break. |
| TLS cert issuance blocked | **None** | No CAA records — Cloudflare Universal SSL issues without obstacle. |
| SaaS ownership re-validation | **Two TXTs to preserve through Step 5** | Both are App Service validation tokens for the `cucox.me` binding on `CucoxResumeApp`. Preserve through the 48-hour overlap; delete in Step 7 after App Service deletion. |
| Active services to migrate | **One** — App Service Web App `CucoxResumeApp` | Linux Node 22 LTS, B1 plan, deployed via GH Actions workflow `azure-deploy.yml` from the source repo. After cutover, both apex and www flow into the cluster via the Tunnel. |
| Backend dependency | **MongoDB Atlas** | App reads from Atlas at runtime via `MONGO_URI`. Cluster pod's egress IP must be on the Atlas IP allowlist before deploy (runbook 05 § Step 4.0). |
| Frontend rebuild required | **No** | Frontend uses `import.meta.env.VITE_BACKEND_URL || ""`; production bundle was built with empty value → relative URLs → same-origin. Cluster Dockerfile preserves this. |
| Subdomain breakage | **None known** | No subdomains beyond `www` are present. The `www` CNAME points at a presumed-deleted SWA → `www.cucox.me` may already be silently 404-ing. Cutover replaces it cleanly. |

---

## Pre-cutover actions (informational, not required)

These are optional hardening steps that can be done at GoDaddy
**before** runbook 05 § Step 5 (NS change) for a smoother cutover.
Promoted into runbook 05 § Step 5.0 as part of the cutover-prep gate.

- **Drop TTLs ~24 hours before cutover.** Edit each record at GoDaddy
  and set TTL to 300s. Doesn't change current behavior; only changes
  how long stale resolvers cache the *old* records during the NS flip.
  With current TTLs of 600–3600s, propagation tail is at most ~1 hour;
  with 300s TTLs, ~5 minutes.

- **Add the cluster's egress IP to the Atlas allowlist** before
  deploying the cluster pod. Discovered via
  `kubectl run egress-probe --rm -it --restart=Never --image=curlimages/curl -- curl -s -4 https://ifconfig.me`.

- **Take a screenshot of the GoDaddy NS values** before changing them.
  This is the literal rollback source if anything goes wrong.

---

## Open questions checklist (Step 7 gate)

All of these MUST be resolved before runbook 05 § Step 7 (old-host
teardown) is allowed to start. Tick each as resolved during the
propagation window.

- [x] **Which Azure App Service does `asuid.cucox.me` validate?**
      Resolved 2026-05-02: `CucoxResumeApp` in subscription `Single
      Pages`, RG `Single_Pages`. Active (not stale).
- [x] **Is the apex A (`20.119.128.24`) still pointing at the same
      Azure resource as `www`?** Resolved 2026-05-02: apex points at
      `CucoxResumeApp` (Web App). `www` points at a Static Web Apps
      hostname that does NOT exist in `Single Pages` subscription —
      orphaned reference.
- [ ] **Verify orphan SWA in other subscriptions.** Run
      `az staticwebapp list` in `Exycle App Subscription` and
      `My DevOps` and confirm no SWA with default hostname matching
      `lemon-mud-0d596dd0f.6.azurestaticapps.net`. If one exists,
      decide whether to delete it (likely yes) before Step 7.
- [ ] **Are there any undocumented subdomains in use?** No evidence in
      the GoDaddy export. Confirm during the propagation window by
      monitoring Cloudflare DNS Analytics for unexpected query patterns
      against `cucox.me`. If any unexpected subdomains appear in
      analytics, investigate before Step 7.
- [ ] **MongoDB Atlas allowlist sanity check.** Confirm the cluster
      egress IP is present and the Azure outbound IPs are still
      present (still needed during the 48-hour overlap). Both invariants
      must hold for the duration of the propagation window. Step 7
      removes the Azure outbound IPs after teardown.

---

## Related files

- GoDaddy export (rollback baseline): `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-2026-05-01.zone`
- GoDaddy NS pre-cutover screenshot (added in 05 § Step 5.0): `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-ns-screenshots/`
- General migration procedure: [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
- Tunnel infrastructure (consumed by this migration): [`03-phase2-cloudflared-tunnel.md`](./03-phase2-cloudflared-tunnel.md)
- Observability that watches the cutover: [`04-phase2-observability.md`](./04-phase2-observability.md)
- App source (gitignored from this repo, in own GitHub repo): `Apps Code/Resume App Updated/my-resume-app-code/` → [Cucox91/my-resume-app](https://github.com/Cucox91/my-resume-app)
- App secrets (SOPS-sealed, decrypted only into pipe memory): `ansible/group_vars/cucox_me/secrets.enc.yaml`
- Architecture reference: ARCH § 6.3 (per-domain ingress dispatch), ARCH § 12 (decision log including ADR-0014 and ADR-0015).
