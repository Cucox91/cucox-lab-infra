# Runbook 05b — Zone-Specific Notes: `exycle.com` (pre-migration state)

> **Purpose:** Capture the pre-migration DNS state for `exycle.com`,
> identify what each record does, and define the record-by-record
> migration plan that runbook 05 will execute. Read alongside
> [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
> when migrating this zone.
>
> **Pattern source:** copied and adapted from
> [`05a-zone-cucox-me-pre-migration.md`](./05a-zone-cucox-me-pre-migration.md)
> (the Phase 2 pilot). Differences from 05a are called out inline so
> the divergence is auditable.
>
> **Scope context:** Beta-stage app, no real production users yet —
> the user has explicitly acknowledged that brief outage windows during
> the migration are acceptable. This relaxes the rollback urgency a
> step relative to cucox.me, but **does NOT relax email integrity** —
> SendGrid-bound MX/SPF/DKIM records must still survive cutover or
> outbound mail starts silently failing on the receiving end.
>
> **Source of truth (zone export):** GoDaddy zone export to be captured
> per Step 1 of runbook 05 at
> `~/Documents/cucox-lab-archive/zone-baselines/exycle.com-godaddy-2026-05-08.zone`.
>
> **Source of truth (Azure resources):** Azure portal review against
> subscription `Exycle App Subscription` (subscription ID TBD by
> operator during inventory step). Resource group, App Service /
> Static Web App, region, and outbound IPs to be captured into the
> table below.

---

## ⚠ Why this is NOT just "05a with the names search-and-replaced"

Three structural differences from cucox.me. Each one requires explicit
handling in the runbook; do not let muscle memory from cucox.me skip
any of them.

| Difference | cucox.me (05a) | exycle.com (this file) |
|---|---|---|
| **Database** | MongoDB Atlas (external, managed) | **Self-hosted Postgres in the cluster** — net-new StatefulSet + PVC + seed Job + backup story. |
| **Email** | None — no MX, SPF, DKIM, DMARC | **SendGrid for outbound** — MX (if any), SPF `include:sendgrid.net`, DKIM CNAMEs (`s1._domainkey`, `s2._domainkey`), and optionally Link Branding CNAMEs must all be preserved verbatim. Step 6.3 of runbook 05 is **active** for this zone. |
| **Object storage** | None | **Cloudinary** — API-key only, outbound HTTPS, no DNS or IP-allowlist concerns. Adds two more SOPS-sealed secrets but no migration risk. |
| **Azure subscription** | `Single Pages` (already inventoried) | `Exycle App Subscription` — **inventory required at Step 1** before runbook 05 starts. Resource names, RG, and outbound IPs are all unknowns at the time of writing. |

---

## Pre-migration baseline snapshot (do this BEFORE Step 1 of runbook 05)

> **Operator action.** Re-run [`00b-proxmox-baseline-snapshot.md`](./00b-proxmox-baseline-snapshot.md)
> with a Phase-2-boundary tag **before any other action in this
> migration**. Rationale: Phase 2 added the `cucox-me` namespace, the
> resume-app Deployment, the Cloudflare zone import, and the
> `cloudflared` config edit. None of that existed at the
> `phase0-clean-2026-04-27` baseline. Without a fresh snapshot, an
> "undo Phase 3" rollback is messy.

```sh
TAG="phase2-pre-exycle-$(date -u +%Y-%m-%d)"
echo "$TAG"
# Expected: phase2-pre-exycle-2026-05-08
```

Run all four layers from runbook 00b with that `TAG`:

- **Layer 1** — recursive ZFS snapshot of `rpool` (and `tank` if it
  exists): instant, free, on-pool. `zfs snapshot -r "rpool@${TAG}"` then
  `zfs hold -r "baseline:${TAG}" "rpool@${TAG}"`.
- **Layer 2** — `zfs send -R | zstd -T0 -19` of `rpool@${TAG}` to
  `/mnt/baseline/${TAG}/rpool-${TAG}.zfs.zst` on the off-pool USB SSD.
  Stream verification via `zstreamdump | tail -20` is non-negotiable.
- **Layer 3** — Clonezilla full-disk image of the boot NVMe to the
  same USB SSD. Skippable only if you took one in the last 30 days
  AND no kernel/bootloader changes have happened since.
- **Layer 4** — config tarball of `/etc`, `/etc/pve`,
  `/var/lib/pve-cluster`, `/root/.ssh`. ~30 seconds.

Companion artifacts (Layer 5 in 00b) at this checkpoint:

- **UniFi backup file** — Settings → System → Backups → Download
  Backup. The zone-firewall rules touched in Phase 0/1 are part of
  the lab's load-bearing config; capture them with the rest.
- **Current `kubectl` resource snapshot** — useful for forensic
  comparison if Phase 3 introduces a regression:
  ```sh
  ssh ubuntu@10.10.20.10 'kubectl get all,ingress,configmap,secret -A -o yaml' \
    > "/mnt/baseline/${TAG}/k8s-all-${TAG}.yaml"
  ```
  Note: Secrets are emitted as base64; this file contains decryptable
  app secrets. Treat it as sensitive — store on the same USB SSD that
  holds the rest of the baseline (offline) and do NOT copy to cloud.
- **Cloudflare zone export for `cucox.me`** — Cloudflare → DNS →
  Records → Export. Records the post-migration state of cucox.me as
  of the moment exycle.com work begins. Saves to
  `/mnt/baseline/${TAG}/cucox.me-cloudflare-${TAG}.zone`.

### Decision gate before Step 1 of runbook 05

- [ ] `zfs list -t snapshot | grep ${TAG}` shows the recursive
      snapshot exists and is held.
- [ ] `/mnt/baseline/${TAG}/rpool-${TAG}.zfs.zst` exists and
      `zstreamdump | tail -20` shows a clean END record.
- [ ] `/mnt/baseline/${TAG}/pve-config-${TAG}.tgz` exists with a
      sha256 in `MANIFEST.md`.
- [ ] UniFi backup file copied into the baseline directory.
- [ ] `k8s-all-${TAG}.yaml` saved to the baseline directory.
- [ ] Baseline USB SSD is unmounted cleanly and physically separated
      from the Ryzen.

If any box is unchecked, do NOT advance to runbook 05 § Step 1.

---

## Step 1 prerequisite — Azure inventory (this is where real Step 1 begins)

Runbook 05 § Step 1 says "inventory existing DNS at GoDaddy". For
`exycle.com`, the parallel action is "inventory existing Azure
resources" — same shape as the 2026-05-02 cucox.me Azure portal review
that produced 05a's "What we now know about the Azure side" table.

Fill in the following table BEFORE editing this file's record-by-record
migration plan:

| Field | Value |
|---|---|
| Resource | `<TBD>` (App Service / Static Web App / Container App / etc.) |
| Subscription | `Exycle App Subscription` (`<subscription-id-TBD>`) |
| Resource group | `<TBD>` |
| Region | `<TBD>` |
| App Service Plan | `<TBD>` (tier + instance count) |
| Runtime stack | `<TBD>` (Node version, Python version, etc.) |
| Default hostname | `<TBD>.azurewebsites.net` |
| Custom domains bound | `exycle.com`, `www.exycle.com` (verify in portal) |
| Virtual IP address | `<TBD>` (matches the apex A record) |
| Outbound IPs | `<TBD,TBD,...>` (Networking blade) |
| App Insights | `<TBD>` (enabled? region? connection string?) |
| Deployment provider | `<TBD>` (GH Actions / Azure DevOps / portal) |
| Last deploy SHA + date | `<TBD>` |
| Existing DB | **None** — Postgres will be self-hosted in the cluster (see § In-cluster Postgres design) |
| Existing object storage | **None** — Cloudinary handles blobs externally |

**Capture the App Service env vars** (Settings → Environment variables,
"Show value" on each) into the table below. The cucox.me migration
discovered that `BACKEND_URL` was set in Azure but unused by the code;
do the same grep-the-source check for any unfamiliar var here. Vars
likely to appear:

| Name | Likely meaning | Action for cluster |
|---|---|---|
| `DATABASE_URL` / `PG_*` | Postgres connection string (currently pointing somewhere external?) | **Replace** — cluster value points at the in-cluster Postgres Service. SOPS-seal the new value. |
| `CLOUDINARY_URL` or `CLOUDINARY_*` | Cloudinary API credentials | **Carry over** as-is. SOPS-seal. |
| `SENDGRID_API_KEY` | SendGrid sending key | **Carry over** as-is, but consider rotating during the cutover (cheap; old key invalidated when revoked from Azure side at Step 7). SOPS-seal. |
| `JWT_SECRET` (or framework equivalent) | Session/auth signing | **Rotate** during cutover (same logic as cucox.me — Beta, no long-lived sessions worth preserving). |
| `CLIENT_URL` / CORS origin | App's own origin | **Replace** with `https://exycle.com`. |
| `PORT` | Listen port | **Carry over** verbatim — Service `targetPort` must match. |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` + friends | App Insights agent | **Drop** — vestigial after cluster migration. Use the runbook 04 Prometheus stack instead. |
| `SEED_DATA` | One-shot seeder flag (if present) | **Must NOT be set in the cluster Deployment** — would re-seed on every pod restart. Run as a separate Job (see § Postgres seed strategy). |

Do not advance to runbook 05 § Step 2 until the table above is filled
in with real values from the Azure portal.

---

## Record inventory (placeholder — fill after Step 1)

Run runbook 05 § Step 1's "save GoDaddy zone export" command, open the
exported file, and fill this table from it. The columns mirror 05a's
Step-1 inventory.

| # | Name | Type | TTL | Value | Function |
|---|---|---|---|---|---|
| 1 | `@` | A or CNAME | `<TTL>` | `<Azure VIP or hostname>` | Apex → Azure resource for `exycle.com` |
| 2 | `@` | NS | 3600 | `ns<XX>.domaincontrol.com.` | GoDaddy authoritative NS |
| 3 | `@` | NS | 3600 | `ns<YY>.domaincontrol.com.` | GoDaddy authoritative NS |
| 4 | `www` | CNAME | `<TTL>` | `<Azure hostname>` | www → same Azure resource |
| 5 | `@` | MX | `<TTL>` | `<priority> <mailserver>` | Inbound mail (if any). Capture every priority. |
| 6 | `@` | TXT | `<TTL>` | `"v=spf1 include:sendgrid.net ~all"` (or similar) | SPF — outbound mail authorization. **Verify the include list matches what SendGrid currently expects** at <https://app.sendgrid.com/settings/sender_auth>. |
| 7 | `s1._domainkey` | CNAME | `<TTL>` | `s1.domainkey.u<XXXXX>.wl<XXX>.sendgrid.net.` | SendGrid DKIM selector 1 — DO NOT CHANGE. |
| 8 | `s2._domainkey` | CNAME | `<TTL>` | `s2.domainkey.u<XXXXX>.wl<XXX>.sendgrid.net.` | SendGrid DKIM selector 2 — DO NOT CHANGE. |
| 9 | `em<XXXX>` | CNAME | `<TTL>` | `u<XXXXX>.wl<XXX>.sendgrid.net.` | SendGrid Link Branding (if enabled). Drop only if Link Branding is being disabled. |
| 10 | `_dmarc` | TXT | `<TTL>` | `"v=DMARC1; p=<policy>; rua=mailto:..."` | DMARC policy. Preserve verbatim. |
| 11 | `@` | TXT | `<TTL>` | `<Azure App Service validation token>` | Azure App Service custom-domain validation. Preserve through Step 5; delete in Step 7. |
| 12 | `asuid` | TXT | `<TTL>` | `<Azure App Service ownership token>` | Azure App Service ownership. Same lifecycle as #11. |
| 13 | `_domainconnect` | CNAME | `<TTL>` | `_domainconnect.gd.domaincontrol.com.` | GoDaddy proprietary auto-config. Drop on migration. |

**Things to actively look for and note:**

- **Multiple MX records** with different priorities — list every one.
- **`mail.exycle.com` A record** — if you receive mail at the domain
  via a self-managed mail server, that's a separate concern. SendGrid
  is outbound-only; receiving mail needs a different MX target.
- **`autodiscover` / `autoconfig` CNAMEs** — present if you ever
  configured Outlook/Apple Mail for this domain.
- **Google / Microsoft / Apple verification TXTs** — `google-site-verification=...`,
  `MS=ms<XXXXX>`, `apple-domain-verification=...`. Each one ties the
  zone to an external SaaS; preserve verbatim.
- **CAA records** — uncommon but possible. If present, ensure
  `letsencrypt.org` and `pki.goog` are allowed (Cloudflare's Universal
  SSL uses Let's Encrypt and Google Trust Services). If only a
  specific CA is allowed, add Cloudflare's CAs explicitly or migration
  cert issuance will fail.

---

## What MUST be preserved verbatim through Cloudflare's auto-import

These records go straight from the GoDaddy export into Cloudflare's
Pending zone with **no value changes**. The auto-import is usually
correct, but Step 2 of runbook 05 explicitly tells you to verify
character-for-character against the export. For exycle.com, these are
the high-stakes ones:

1. **MX records** — every priority, exact target hostname. A missing
   priority or a typo in the target = inbound mail bounces.
2. **SPF TXT** — exact include list. A missing `include:sendgrid.net`
   = outbound mail from SendGrid fails SPF on the receiver side, lands
   in spam or is rejected.
3. **DKIM CNAMEs** (`s1._domainkey`, `s2._domainkey`, and any Link
   Branding CNAMEs `em<XXXX>` / `url<XXXX>`) — these point at
   SendGrid's DKIM signing infrastructure. A wrong target = DKIM fail
   = mail goes to spam.
4. **DMARC TXT** (`_dmarc`) — exact policy + reporting addresses. A
   missing or weakened DMARC during the propagation window is an
   actively exploited spoofing window.
5. **Azure App Service validation TXTs** (`@ "..."`, `asuid`) — same
   logic as cucox.me's 05a. Preserve through the propagation window;
   the App Service may revalidate the binding, and a missing TXT will
   silently unbind the custom domain server-side. Delete only at
   Step 7 after the App Service is gone.

---

## Records that get replaced (not preserved)

Two records flip from "Azure-bound" to "Tunnel-bound" via Terraform in
runbook 05 § Step 3.1:

- **Apex A** `<Azure VIP>` → **Apex CNAME** `<TUNNEL_UUID>.cfargotunnel.com`
  (orange-clouded). Same Cloudflare apex CNAME flattening behavior as
  cucox.me — the flattening is gated on zone-Active state, so the
  "click Check nameservers now" step in runbook 05 § Step 5.1 is just
  as important here.
- **www CNAME** `<Azure hostname>` → CNAME `<TUNNEL_UUID>.cfargotunnel.com`
  (orange-clouded).

The old Azure App Service must remain reachable through the 48-hour
propagation gate. Do not pre-delete the old A record at GoDaddy.

---

## Records that can be dropped at migration time

- **`_domainconnect` CNAME** — GoDaddy-proprietary, no function on
  Cloudflare nameservers.
- **Anything tied to a SaaS that has been retired** — if Azure App
  Service validation tokens predate a binding rotation, or a
  Google verification points at a property you no longer own, drop
  rather than carry forward. Note any drops in the per-zone tracking
  table at the bottom of this file.

---

## Migration plan (record-by-record)

| Record | Today (GoDaddy) | After Cloudflare zone import (Pending) | After runbook 05 § Step 3 (Tunnel CNAMEs) | After runbook 05 § Step 7 (App Service teardown) |
|---|---|---|---|---|
| Apex A/CNAME | A `<Azure VIP>` | unchanged (grey) | **CNAME `<UUID>.cfargotunnel.com`** (orange, Terraform) | unchanged |
| `www` CNAME | `<Azure hostname>` | unchanged (grey) | **CNAME `<UUID>.cfargotunnel.com`** (orange, Terraform) | unchanged |
| MX | `<priority> <target>` | preserved verbatim (grey) | unchanged | unchanged |
| SPF TXT (`@`) | `v=spf1 include:sendgrid.net ~all` | preserved verbatim | unchanged | unchanged |
| DKIM CNAMEs (`s1._domainkey`, `s2._domainkey`, `em<XXXX>`) | `*.sendgrid.net.` | preserved verbatim (grey — DKIM CNAMEs cannot be proxied) | unchanged | unchanged |
| DMARC TXT (`_dmarc`) | `v=DMARC1;...` | preserved verbatim | unchanged | unchanged |
| Azure validation TXT (`@`, `asuid`) | App Service token | preserved verbatim | preserved | **delete** |
| `_domainconnect` CNAME | GoDaddy auto-config | optional (drop) | dropped | dropped |
| NS | `ns<XX/YY>.domaincontrol.com.` | unchanged (still GoDaddy) | unchanged | replaced at registrar by Cloudflare NS in 05 § Step 5 |

> **Cloudflare proxy cloud color rule of thumb:**
> - **Orange (proxied):** records that resolve to a Cloudflare anycast
>   IP and traffic flows through the edge. Apex + `www` → Tunnel CNAMEs
>   are the only orange entries here.
> - **Grey (DNS only):** every email-related record (MX, SPF TXT, DKIM
>   CNAMEs, Link Branding CNAMEs, DMARC TXT). Cloudflare does not proxy
>   SMTP. Never orange-cloud an email record.

---

## In-cluster Postgres design

Net-new vs. cucox.me. The cucox.me app uses Atlas; exycle is moving to
self-hosted Postgres in the cluster. Below is the chosen shape and the
"why" behind each decision.

### Shape

```
Namespace: exycle-com
├── StatefulSet: exycle-pg (1 replica, image postgres:16-alpine)
│   └── PVC: exycle-pg-data (10Gi, storageClassName local-path)
├── Service: exycle-pg (ClusterIP, port 5432) — DNS: exycle-pg.exycle-com.svc.cluster.local
├── ConfigMap: exycle-pg-init (one-shot SQL: CREATE DATABASE / CREATE ROLE / GRANT)
├── Secret: exycle-pg-creds (postgres admin password, app role password)
├── Job: exycle-pg-seed (one-shot: applies the MVP seed SQL; not retried on Deployment restart)
├── Deployment: exycle-web (the app, 1 replica, image ghcr.io/...)
└── Ingress: exycle (host exycle.com + www.exycle.com, ingressClassName nginx)
```

### Decisions and trade-offs

- **StatefulSet over plain Deployment.** A StatefulSet gives a stable
  pod name (`exycle-pg-0`) and stable PVC binding. If the pod is
  rescheduled, the same PVC re-attaches. A Deployment with `volumeClaimTemplates`
  doesn't exist; you'd have to manage the PVC separately. StatefulSet
  makes the dataset's identity explicit.
- **Single replica, no operator.** Beta-stage, single-node cluster,
  one app: a Postgres operator (CloudNativePG, Zalando, Crunchy) is
  significant complexity tax that buys nothing until there are
  multiple workers and you want HA. We can graduate to an operator in
  Phase 4 when the second worker comes online; for now, vanilla
  StatefulSet + PVC is right-sized.
- **`storageClassName: local-path`.** k3s ships with the Rancher
  local-path-provisioner as the default. PVCs land on the worker
  node's local filesystem (`/var/lib/rancher/k3s/storage/...`). Fine
  for a Beta DB on a single-node cluster — the node IS the failure
  domain regardless. When `tank` lands per ADR-0011 and a second
  worker exists, migrate to a PVC backed by an NFS export from `tank`
  for cross-node-resilient storage.
- **Image: `postgres:16-alpine`.** Small attack surface, recent stable.
  Pin a specific minor (e.g. `postgres:16.4-alpine`) in the actual
  manifest so an upstream `:16-alpine` retag doesn't surprise the
  pod on next pull.
- **PSA: namespace gets `enforce: restricted`.** Same as cucox-me.
  Postgres runs happily as a non-root user (`runAsUser: 999` is the
  postgres image's default uid). `readOnlyRootFilesystem: false` —
  Postgres writes to `/var/lib/postgresql/data` (PVC-mounted) and
  `/tmp`; the rootfs has nothing to write.
- **Backups (out of scope of Step 4, in scope of Phase 3 close-out).**
  At minimum: `pg_dump` cron Job to the `tank` pool when it exists,
  or to the same Mac Air SSD that holds the baseline snapshots in
  the meantime. Add as a separate runbook (`07-postgres-backup.md`)
  when this migration completes — explicitly NOT a blocker for the
  Beta-stage cutover.

### Postgres seed strategy

The user said "I want to host AND seed in the server". Two-step pattern:

1. **`exycle-pg-init` ConfigMap** — mounted at
   `/docker-entrypoint-initdb.d/00-init.sql` inside the container. The
   official `postgres` image runs every `*.sql` file in that
   directory **on the very first start of an empty data directory and
   never again**. So:

   ```sql
   -- 00-init.sql
   CREATE DATABASE exycle;
   CREATE ROLE exycle_app WITH LOGIN PASSWORD :'app_password';
   GRANT ALL PRIVILEGES ON DATABASE exycle TO exycle_app;
   ```

   The image's entrypoint substitutes `:'app_password'` from an env
   var. Read [the postgres image docs](https://hub.docker.com/_/postgres)
   § "Initialization scripts" for exact syntax.

2. **`exycle-pg-seed` Job** — runs the application's seed SQL (the
   data the user authored as part of the MVP). Two choices:

   - **(a)** Bundle the seed SQL into a ConfigMap and mount into a
     `psql` Job that targets the `exycle-pg` Service. Idempotent
     guards in the SQL (`INSERT ... ON CONFLICT DO NOTHING`) protect
     against accidental re-runs.
   - **(b)** Add a `npm run seed` (or framework equivalent) to the
     app's `package.json` and run that as a Job that pulls the same
     image as the web Deployment, with `command: ["node", "dist/seed.js"]`.

   **Pick (b)** if the app already has a seed script (most MVPs do —
   the user said "seed in the server" implying app-level seed code).
   Match the seed code's idempotency to the Job's `restartPolicy: OnFailure`.

   The Job runs once at deploy time. **Never** put the seed in the
   Deployment's container — that re-runs on every pod restart.

### App connection string

Construct the cluster `DATABASE_URL` from the Service DNS:

```
postgresql://exycle_app:<app_password>@exycle-pg.exycle-com.svc.cluster.local:5432/exycle
```

Encrypted into the same SOPS file as Cloudinary + SendGrid keys (see
§ Secrets layout below). The app reads it from a Secret-mounted env
var, same as cucox.me's `MONGO_URI`.

---

## Cloudinary / SendGrid backend plan

### Cloudinary

- **DNS impact:** none. Cloudinary is API-only over HTTPS.
- **Secrets:** copy `CLOUDINARY_URL` (or `CLOUDINARY_CLOUD_NAME` +
  `CLOUDINARY_API_KEY` + `CLOUDINARY_API_SECRET` — depends which form
  the SDK reads) verbatim from Azure App Service env vars.
- **Allowlist:** Cloudinary's free/pay-as-you-go tiers don't enforce
  IP allowlists. If you've enabled "Restricted IPs" in the Cloudinary
  dashboard (Settings → Security), add the cluster egress IP — same
  IP discovered for Atlas in cucox.me's Step 4.0.
- **Migration risk:** zero unless you've configured Restricted IPs.

### SendGrid

- **DNS impact:** **load-bearing** — see § Records that MUST be
  preserved verbatim. SPF include + DKIM CNAMEs + (optional) Link
  Branding CNAMEs all point at SendGrid hostnames. Surviving the
  Cloudflare auto-import unchanged is the entire ballgame.
- **Secrets:** `SENDGRID_API_KEY` carries over verbatim.
- **Sender authentication state in SendGrid dashboard:** sign in to
  <https://app.sendgrid.com/settings/sender_auth> and confirm `exycle.com`
  shows green check marks for SPF + DKIM. If anything is yellow or
  red there *before* the migration, fix it at SendGrid first;
  troubleshooting auth failures while *also* migrating DNS is asking
  to chase a red herring.
- **Allowlist:** SendGrid's outbound API doesn't allowlist source IPs.
  No prep needed.
- **Migration risk:** SPF/DKIM auth fail on receiving side if any of
  the SendGrid-bound records are mistyped during the Cloudflare
  auto-import. Step 6.3 (email validation) catches this; ship a test
  email both directions during the propagation window.
- **Optional rotation:** generate a new SendGrid API key during the
  cutover and revoke the old one at Step 7 alongside the Azure
  publish profile. Same reasoning as JWT — Beta, no long-lived key
  state to preserve.

---

## Migration risk profile

| Concern | Status | Notes |
|---|---|---|
| Email disruption (inbound) | **Real, mitigated by record-preservation** | MX records exist; Cloudflare auto-import must reproduce them exactly, grey-clouded. Verify in Step 2 of runbook 05. |
| Email disruption (outbound, via SendGrid) | **Real, mitigated by record-preservation** | SPF + DKIM CNAMEs must be preserved verbatim. Mistype = mail goes to spam on receiving end — silent and slow to detect. |
| TLS cert issuance blocked | **None expected** | No CAA records anticipated; if any are present in the GoDaddy export, ensure Let's Encrypt + Google Trust Services + Cloudflare's CAs are allowed. |
| SaaS ownership re-validation | **Two TXTs to preserve through Step 5** | Azure App Service validation token + `asuid`. Same lifecycle as cucox.me. |
| Active services to migrate | **One web app + one new in-cluster Postgres** | App on Azure → cluster. New Postgres StatefulSet + PVC + seed Job. |
| Backend dependency: Cloudinary | **Trivial** | API-only, secrets carry over, no DNS or allowlist concerns. |
| Backend dependency: SendGrid | **DNS-load-bearing only** | API key carries over; the DNS preservation work above is the actual concern. |
| Backend dependency: Postgres | **Net-new in cluster** | Section above. Single point of failure on a single-node cluster — acceptable for Beta, scheduled for HA in Phase 4. |
| Frontend rebuild required | **TBD** | Inventory step needs to confirm whether the frontend is built with hardcoded `VITE_*` URLs or relative ones (cucox.me uses relative). If hardcoded to the Azure hostname, rebuild with `https://exycle.com` before cutover. |
| Subdomain breakage | **TBD** | If any subdomains exist beyond `www`, list them in the Open Questions checklist below. |

---

## Pre-cutover actions (informational, not required)

These lower the propagation tail and tighten rollback posture. Same
trio as cucox.me 05a; same caveats apply.

- **Drop record TTLs to GoDaddy's minimum (600s on personal plans)
  ~24 hours before cutover.** Per the GoDaddy minimum-TTL memo, 300
  is rejected on personal plans; accept 600.
- **Add the cluster's egress IP to the Cloudinary Restricted IPs list**
  (only if Restricted IPs is enabled). Discover via:
  ```sh
  kubectl run egress-probe --rm -it --restart=Never --image=curlimages/curl -- curl -s -4 https://ifconfig.me
  ```
- **Take a screenshot of GoDaddy's NS values + the full DNS records
  list** before changing anything. Save next to the zone export at
  `~/Documents/cucox-lab-archive/zone-baselines/exycle.com-ns-screenshots/`.

---

## Secrets layout (cluster side)

SOPS-sealed file at `ansible/group_vars/exycle_com/secrets.enc.yaml`:

```yaml
# decrypts to:
postgres_admin_password: <generated, e.g. `openssl rand -base64 32`>
postgres_app_password:   <generated, separate from admin>
database_url:            postgresql://exycle_app:<app_password>@exycle-pg.exycle-com.svc.cluster.local:5432/exycle
cloudinary_url:          <copied from Azure App Service env vars>
sendgrid_api_key:        <copied or rotated>
jwt_secret:              <rotated; new value>
# ...any other env vars discovered during inventory
```

Sealed via the same `sops --encrypt --filename-override ... --input-type yaml --output-type yaml /dev/stdin > <file>`
streaming pattern as cucox.me Step 4.1 — plaintext never lands on disk.

The k8s `Secret` is applied via the same pipe-to-`kubectl-apply` pattern
as cucox-me, with two sub-secrets:

- `exycle-pg-creds` — `POSTGRES_PASSWORD` (admin) + `POSTGRES_APP_PASSWORD`
  (app role) → consumed by the StatefulSet env + the init SQL.
- `exycle-com-secrets` — `DATABASE_URL` + `CLOUDINARY_URL` +
  `SENDGRID_API_KEY` + `JWT_SECRET` → consumed by the web Deployment
  via `envFrom: secretRef`.

---

## Open questions checklist (Step 7 gate)

All must be resolved before runbook 05 § Step 7 (old-host teardown) is
allowed to start. Tick during the propagation window.

- [ ] **Azure inventory complete.** All `<TBD>` cells in the table at
      the top of this file replaced with real values.
- [ ] **GoDaddy zone export captured** at
      `~/Documents/cucox-lab-archive/zone-baselines/exycle.com-godaddy-2026-05-XX.zone`.
- [ ] **Frontend build mode confirmed.** Either: relative URLs (no
      rebuild) or hardcoded URLs (rebuild required + new image
      pushed) — explicitly noted before cutover.
- [ ] **SendGrid sender authentication state** is green for
      `exycle.com` in the SendGrid dashboard *before* migration starts.
- [ ] **DKIM CNAMEs match** between GoDaddy export and SendGrid's
      "Authenticate Your Domain" page (current expected values).
- [ ] **Cluster egress IP added to Cloudinary Restricted IPs** (if
      Restricted IPs is enabled) — or confirmed not enabled.
- [ ] **Postgres seed Job has been tested in a scratch namespace**
      against an ephemeral PVC at least once before the cutover. Seed
      scripts that look right but fail mid-INSERT cost a long
      Saturday.
- [ ] **Postgres backup story exists**, even if only "manual `pg_dump`
      to the Mac Air every Sunday until runbook 07 lands". An empty
      backup story is fine for a Beta gate; a *missing* backup story
      is not — write it down somewhere.
- [ ] **Test email sent both directions** through SendGrid during the
      propagation window. Receiver headers show SPF=pass, DKIM=pass,
      DMARC=pass.
- [ ] **No undocumented subdomains** appearing in Cloudflare DNS
      Analytics during the propagation window. If any do, investigate
      before Step 7.

---

## Phase ordering at a glance

For quick reference; each step links into the existing runbooks where
the actual procedure lives.

| # | Phase | Where | Output |
|---|---|---|---|
| 0 | Take Phase 2 baseline snapshot | [`00b`](./00b-proxmox-baseline-snapshot.md) with `TAG=phase2-pre-exycle-2026-05-08` | USB SSD with all four layers + UniFi backup + `kubectl get all` dump |
| 1 | Inventory Azure + GoDaddy | This file § Azure inventory + [`05` § Step 1](./05-dns-godaddy-to-cloudflare.md#step-1--inventory-existing-dns-at-godaddy) | Filled-in tables in this file |
| 2 | Create Cloudflare zone (Pending) | [`05` § Step 2](./05-dns-godaddy-to-cloudflare.md#step-2--create-the-cloudflare-zone) | Zone in Pending state, auto-import verified against GoDaddy export |
| 3 | Add Tunnel CNAMEs + cloudflared rules | [`05` § Step 3](./05-dns-godaddy-to-cloudflare.md#step-3--add-the-tunnel-cnames-and-cloudflared-ingress-rules) (Terraform + cloudflared config edit) | Apex + www CNAMEs in Cloudflare, both orange; ingress rules live on `lab-edge01` |
| 4a | Stand up Postgres in cluster | This file § In-cluster Postgres design (manifests under `k8s/apps/exycle-com/`) | StatefulSet + PVC + Service + Secret + init SQL ConfigMap |
| 4b | Run seed Job, verify with `psql` | This file § Postgres seed strategy | Seed data present and queryable |
| 4c | Build + push container image to GHCR | Same flow as [`05` § Step 4.2](./05-dns-godaddy-to-cloudflare.md#42--build-and-push-the-container-image-to-ghcr) | `ghcr.io/cucox91/exycle-app:<tag>` (public) |
| 4d | Apply web Deployment + Service + Ingress | Same flow as [`05` § Step 4.3](./05-dns-godaddy-to-cloudflare.md#43--apply-the-k8s-manifests) | Pod Ready 1/1, logs show DB connected + server listening |
| 4e | Smoke test via `curl --resolve` | [`05` § Step 4.5](./05-dns-godaddy-to-cloudflare.md#45--pre-cutover-smoke-test-through-the-cluster-path) | `HTTP/2 200` for apex + www + a representative `/api` route |
| 5 | Cutover (NS change at GoDaddy) | [`05` § Step 5](./05-dns-godaddy-to-cloudflare.md#step-5--cutover-change-nameservers-at-godaddy) | Cloudflare NS active; "Check nameservers now" clicked immediately |
| 6 | Validate (web + API + email + dashboards) | [`05` § Step 6](./05-dns-godaddy-to-cloudflare.md#step-6--validation), including § 6.3 email validation | All checks pass at +1h, +6h, +24h, +48h |
| 7 | Tear down old Azure host | [`05` § Step 7.A](./05-dns-godaddy-to-cloudflare.md#7a--old-host-is-a-managed-paas-azure-app-service-azure-static-web-apps-vercel-netlify-etc) | App Service stopped → deleted; App Service Plan deleted; App Insights deleted; Azure validation TXTs removed from Cloudflare |

The 48-hour gate between Step 5 and Step 7 is **not optional even for
Beta** — it's the rollback safety net during NS propagation, and
losing it costs the ability to recover by reverting NS at GoDaddy.
The "this is Beta, no real users" relaxation applies to Steps 4 and 6
(brief smoke-test outages are tolerable), not to the propagation gate.

---

## Related files

- General migration procedure: [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
- Pattern source (cucox.me notes): [`05a-zone-cucox-me-pre-migration.md`](./05a-zone-cucox-me-pre-migration.md)
- Pre-migration baseline: [`00b-proxmox-baseline-snapshot.md`](./00b-proxmox-baseline-snapshot.md)
- Tunnel infrastructure (consumed by this migration): [`03-phase2-cloudflared-tunnel.md`](./03-phase2-cloudflared-tunnel.md)
- Observability that watches the cutover: [`04-phase2-observability.md`](./04-phase2-observability.md)
- App source (gitignored, in own GitHub repo TBD): `Apps Code/Exycle App/` → `<github-url-TBD>`
- App secrets (SOPS-sealed, decrypted only into pipe memory): `ansible/group_vars/exycle_com/secrets.enc.yaml`
- Architecture reference: ARCH § 6.3 (per-domain ingress dispatch), ARCH § 12 (decision log).
- Future: ADR-0017 (in-cluster Postgres choice and seed strategy) — write at end of Phase 3 close-out.
- Future: `07-postgres-backup.md` — Postgres backup runbook, not blocking this migration.

---

## Per-zone tracking row (for runbook 05's table)

When this migration completes, append to runbook 05's per-zone table:

| Zone | Status | NS-changed-at | Old-host-decommissioned-at | Notes |
|---|---|---|---|---|
| `exycle.com` | in-progress | — | — | Phase 3 first; in-cluster Postgres + SendGrid DNS preservation; Beta-stage |
