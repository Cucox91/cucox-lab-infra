# Runbook 05 — DNS Migration: GoDaddy → Cloudflare

> **Goal:** Move authoritative DNS for one zone from GoDaddy to Cloudflare
> with **zero downtime for the website and zero email disruption**, enabling
> that zone's hostnames to be served via the Cloudflare Tunnel into the lab.
>
> **Example zone in this runbook:** `cucox.me`. Repeat the procedure
> per-domain. `cucox.me` is the Phase 2 pilot; `exycle.com` and
> `cucoxcorp.com` follow in Phase 3.
>
> **Estimated time:** ~30 minutes of active hands-on work plus a 48-hour
> validation gate before old-host teardown. The 48-hour gate is
> non-negotiable; it is the rollback safety net during the propagation
> tail.
>
> **Operator:** Raziel, Mac Air on `CucoxLab-Mgmt` (VLAN 10).

---

## Note on early-start state from runbook 03

The Phase 2 pilot zone (`cucox.me`) may already be partially through
**Step 1** (GoDaddy DNS inventory) and **Step 2** (Cloudflare zone
created in Pending state) when this runbook is opened.

Runbook 03 § Step 2.0 pulls these forward to bootstrap the
`cloudflared tunnel login` flow (Cloudflare requires at least one zone
in the account before a CLI Origin Certificate can be issued). When that
happens:

- The GoDaddy export already exists at
  `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-<date>.zone`.
- The zone exists in Cloudflare in **Pending Nameserver Update** state,
  with auto-imported records already verified against the GoDaddy
  export.
- Per-zone analysis (record-by-record migration plan, what to preserve,
  what to drop) lives in [`05a-zone-cucox-me-pre-migration.md`](./05a-zone-cucox-me-pre-migration.md).

**For `cucox.me` as of 2026-05-02** — Steps 1 and 2 are complete. The
GoDaddy zone export is captured at
`~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-2026-05-01.zone`,
the zone is Pending in Cloudflare with the auto-import draft verified,
and the tunnel `cucox-lab-prod` is HEALTHY with 4 connections per
runbook 03 close-out. **Skip ahead to § Step 3** after re-reading the
per-zone notes file for the App Service / Atlas context (the 05a
record-attribution was corrected on 2026-05-02 against direct Azure
portal confirmation).

**For a later zone (`exycle.com`, `cucoxcorp.com`)** — proceed with
this runbook's Step 1 normally, and create a new
`05a-zone-<name>-pre-migration.md` from the cucox.me template.

---

## Prerequisites

- Cloudflare account exists (free plan is sufficient).
- Phase 0 + Phase 1 + Phase 2 cluster bring-up complete. Specifically:
  - `lab-edge01` is running with `cloudflared` connected to a Tunnel
    named `cucox-lab-prod`. HEALTHY in the Cloudflare dashboard with
    4 connections.
  - `ingress-nginx` (chart `4.11.8`) is running in the cluster behind
    the MetalLB VIP `10.10.20.50` (pinned per runbook 02 § 6.1).
  - `kube-prometheus-stack 84.5.0` is running with the three Cucox Lab
    landing dashboards (per runbook 04). Grafana resolves on the Mac Air
    via `/etc/hosts` → `grafana.lab.cucox.local` → `10.10.20.50`.
  - Outbound 443/7844 is allowed from `dmz` to the internet.
- GoDaddy admin access for the zone being migrated.
- A scoped Cloudflare API token with `Zone:DNS:Edit` for all zones in
  the account (used by Terraform under `terraform/cloudflare/`).
  Created in runbook 03 § Step 1, sealed at
  `terraform/cloudflare/secrets.enc.yaml`.
- An app to put behind the new hostname. For the `cucox.me` pilot this
  is the containerized resume site (Express + Vite SPA, monorepo at
  `Apps Code/Resume App Updated/my-resume-app-code/` per project
  convention; `Apps Code/` is gitignored from this repo). Image hosted
  on GHCR at `ghcr.io/cucox91/my-resume-app:<tag>` (public — no
  `imagePullSecrets` required).
- MongoDB Atlas account with the cluster's egress IP allowlisted
  (Step 4.0).

---

## Scope of one migration

For a single zone (`cucox.me`), the migration touches:

1. Inventory of existing DNS at GoDaddy (Step 1).
2. Cloudflare zone creation + record import + verification (Step 2).
3. Tunnel CNAMEs + `cloudflared` ingress rules (Step 3).
4. In-cluster app deployment + `Ingress` resource (Step 4), including:
   - Atlas connectivity prep (Step 4.0).
   - SOPS-sealed app secrets (Step 4.1).
   - Container image build + push (Step 4.2).
   - Manifest apply (Step 4.3).
   - Pod-health verification (Step 4.4).
   - Pre-cutover smoke test through the cluster path (Step 4.5).
5. Pre-cutover prep + cutover (Step 5).
6. Validation (Step 6) — web + API + (when applicable) email +
   propagation monitoring + dashboard watch.
7. Old-host teardown (Step 7) — gated on validation + 48 hours +
   resolution of the per-zone Open Questions checklist.

---

## Step 1 — Inventory existing DNS at GoDaddy

> **For `cucox.me`:** complete. Skip to Step 2.
> **For a future zone:** follow this section.

In the GoDaddy DNS dashboard for the zone, capture every record:

- **A / AAAA** — typically the apex pointing to the current host.
- **CNAME** — `www`, `mail`, `cdn.*`, etc.
- **MX** — email mail-exchanger records. **DO NOT BREAK THESE.**
- **TXT** — SPF (`v=spf1 ...`), DKIM (`*._domainkey.*`), DMARC (`_dmarc`),
  domain-verification records (Google Search Console, Apple, Microsoft 365,
  GitHub Pages, Azure App Service `asuid`, etc.).
- **SRV** — uncommon, but check.
- **NS** at non-apex levels (delegated subdomains) — uncommon.

Record any GoDaddy-specific services in use:

- **Domain forwarding** → must be replaced with a Cloudflare Page Rule or
  Bulk Redirect.
- **GoDaddy Email / Microsoft 365 via GoDaddy** → MX + autodiscover
  records must be preserved exactly. Account billing is unaffected by the
  DNS move.
- **WHOIS privacy** → unaffected (registrar-level setting at GoDaddy).

**Save a screenshot or text export of the full zone** outside the repo:

```sh
mkdir -p ~/Documents/cucox-lab-archive/zone-baselines
mv ~/Downloads/<zone>.txt ~/Documents/cucox-lab-archive/zone-baselines/<zone>-godaddy-$(date +%Y-%m-%d).zone
```

This is non-negotiable; it's your rollback baseline.

---

## Step 2 — Create the Cloudflare zone

> **For `cucox.me`:** complete (zone in Pending state per runbook 03 §
> Step 2.0). Skip to Step 3.
> **For a future zone:** follow this section.

In the Cloudflare dashboard:

1. **Add Site → enter `<zone>` → Free plan.**
2. Cloudflare runs an automatic record scan and pre-populates a draft of
   the zone with whatever it could resolve from public DNS.
3. **Verify every record in the draft against your Step 1 export.**
   Especially:
   - **MX records** — must match exactly, including priorities.
   - **SPF** TXT — exact match; one missing `include:` and legitimate
     mail starts going to spam.
   - **DKIM** TXT (often a long key under a selector like
     `selector1._domainkey` or `s1._domainkey`) — exact match.
   - **DMARC** TXT (`_dmarc`) — exact match including the policy and
     reporting addresses.
   - **Verification TXT** records for any IdP / SaaS that proved
     ownership of the domain (e.g. Azure App Service `asuid`).
4. For records that point to the **current external host of the
   website** — these will be replaced in Step 3, but for now leave them
   matching GoDaddy:
   - **Email-related records (MX, mail.*) → grey cloud (DNS only).**
     Cloudflare does not proxy SMTP. Email records are *always* grey.
   - **Application-related (the apex A or CNAME pointing at the old web
     host) → grey cloud for now.** You will flip these to orange and
     repoint to the Tunnel CNAME in Step 3.
5. Note the two nameservers Cloudflare assigns you (e.g.
   `ana.ns.cloudflare.com`, `chuck.ns.cloudflare.com`).

> **Do NOT click "Done, check nameservers" yet.** The zone is staged in
> Cloudflare but no resolver in the world is asking it for answers.

---

## Step 3 — Add the Tunnel CNAMEs and `cloudflared` ingress rules

The pattern for a Tunnel-backed hostname is:

- **Cloudflare CNAME**: `<zone> → <TUNNEL_UUID>.cfargotunnel.com`,
  proxied (orange cloud).
- **Cloudflare CNAME**: `www.<zone> → <TUNNEL_UUID>.cfargotunnel.com`,
  proxied.
- **`cloudflared` ingress rule** that maps each hostname to the
  in-cluster ingress VIP `https://10.10.20.50:443` with a per-route
  `httpHostHeader`. **`httpHostHeader` is mandatory** per
  [ADR-0014](../decisions/0014-cloudflared-edge-vm-upstream-vip.md):
  the upstream is an IP, not a hostname, so without `httpHostHeader`
  cloudflared sends `Host: 10.10.20.50` to nginx and no `Ingress`
  rule matches.

### 3.1 — Add Tunnel CNAMEs via Terraform

The zone already exists in Cloudflare (created in runbook 03 § Step 2.0
in Pending state). Terraform needs to **import** the existing zone, not
create a new one — creating would error with "zone already exists".

Create `terraform/cloudflare/cucox-me-zone.tf`:

```hcl
# cucox.me Cloudflare zone — created out-of-band in runbook 03 § Step 2.0
# (Add a Site wizard, stopped before the "check nameservers" step).
# Imported into Terraform state by the declarative import block below.

import {
  to = cloudflare_zone.cucox_me
  id = var.cucox_me_zone_id
}

resource "cloudflare_zone" "cucox_me" {
  account_id = var.cloudflare_account_id
  zone       = "cucox.me"
  plan       = "free"

  # paused/jump_start can drift from Cloudflare's defaults across UI
  # actions; ignore so subsequent plans don't propose churn.
  lifecycle {
    ignore_changes = [paused, jump_start, type]
  }
}

output "cucox_me_zone_id" {
  description = "Zone ID for cucox.me. Used by record resources."
  value       = cloudflare_zone.cucox_me.id
}
```

Add the variable in `terraform/cloudflare/variables.tf`:

```hcl
variable "cucox_me_zone_id" {
  type        = string
  description = "Cloudflare zone ID for cucox.me. Captured from the Cloudflare dashboard sidebar (Websites → cucox.me → Overview → API → Zone ID). Imported, not created — see runbook 05 § Step 3.1."
}
```

Then create `terraform/cloudflare/cucox-me-records.tf`:

```hcl
# cucox.me DNS records — Tunnel-backed hostnames (apex + www).
# The remaining records (TXT _gaiibn..., TXT asuid, etc.) stay in
# Cloudflare's auto-imported state and are NOT managed by Terraform
# until Step 7 cleans them up — managing them here would require
# importing each individually and is unnecessary churn for records
# that are scheduled for deletion.

resource "cloudflare_record" "cucox_me_apex" {
  zone_id = cloudflare_zone.cucox_me.id
  name    = "@"
  type    = "CNAME"
  content = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.cname
  proxied = true
  ttl     = 1     # 1 = Auto (required when proxied = true)
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
```

> **`content` vs `value`.** Cloudflare provider v4.x renamed
> `cloudflare_record.value` to `content` (deprecation began at v4.0,
> made canonical thereafter). The cached provider in this repo is
> 4.52.7. If `terraform validate` rejects `content` (unexpected;
> documented as the v4.x argument), swap to `value` and capture the
> swap in the runbook commit message — that means the cached version
> behaves differently than expected.
>
> **`cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.cname`**
> is the provider's built-in CNAME target output (equivalent to
> `<TUNNEL_UUID>.cfargotunnel.com`). Consuming it directly avoids
> hand-building the string and keeps the dependency graph explicit.

**Pre-apply check (lesson learned during the 2026-05-02 cucox.me run):**
Cloudflare's "Add a Site" auto-import (runbook 03 § Step 2.0.2) brings
along the zone's existing public DNS records. For a zone migrating
*from* a managed PaaS (Azure App Service, Static Web Apps, Vercel,
Netlify, etc.), this typically means the apex A (or apex CNAME) and
the `www` CNAME already exist in Cloudflare's copy of the zone.

Cloudflare's API rejects creating a second record at the same name —
even of a different type (apex `A` + apex `CNAME` cannot coexist per
RFC 1912; Cloudflare's CNAME flattening doesn't override the API
uniqueness check). If you don't pre-empt this, the `terraform apply`
fails partway with:

```
Error: expected DNS record to not already be present but already exists
```

— and any successfully-imported resources up to that point are now in
state, so the saved plan goes stale (`Error: Saved plan is stale`).

**Before running `terraform plan`**, dashboard-delete the two records
that Step 3.1 is replacing:

1. Cloudflare → Websites → `<zone>` → DNS → Records.
2. Find the **apex A** (or apex CNAME pointing at the old host) and
   delete it via the row's `...` menu.
3. Find the **`www` CNAME** pointing at the old host and delete it.

**Keep** the TXT records (e.g. `_gaiibn...`, `asuid` for Azure App
Service custom-domain validation) and any `_domainconnect` CNAME.
Those get cleaned up in runbook 05 § Step 7 after the App Service is
torn down.

This is fully reversible during the migration window: nothing public
resolves via Cloudflare's nameservers for this zone yet (the
authoritative NS is still GoDaddy until § Step 5), so deleting the
Cloudflare-side copies is invisible to public visitors.

If you've already hit the error mid-apply: dashboard-delete the
conflicting records, then re-run `terraform plan -out=cucox-me.plan`
(the saved plan is stale and must be regenerated), then re-apply.

---

Apply (one-liner per the paste-fragility memo — backslash-continued
multi-line shell blocks corrupt easily):

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/terraform/cloudflare" && export TF_VAR_cloudflare_api_token="$(sops --decrypt secrets.enc.yaml | yq -r .cloudflare_api_token)" && export TF_VAR_cloudflare_account_id="<your account id>" && export TF_VAR_tunnel_uuid="$(cat ~/.scratch/tunnel-uuid)" && export TF_VAR_tunnel_secret="$(sops --decrypt ../../ansible/group_vars/lab_edge/tunnel-creds.enc.json | jq -r .TunnelSecret)" && export TF_VAR_cucox_me_zone_id="<paste from Cloudflare dashboard>" && terraform plan -out=cucox-me.plan
```

Review the plan. Expect three resources to be created/imported:

- `cloudflare_zone.cucox_me` (imported, no changes).
- `cloudflare_record.cucox_me_apex` (created).
- `cloudflare_record.cucox_me_www` (created).

If plan shows changes to the imported zone, adjust the `lifecycle.ignore_changes`
list in `cucox-me-zone.tf` until plan is clean for the import target.

Apply:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/terraform/cloudflare" && terraform apply cucox-me.plan
```

Verify in the Cloudflare dashboard → `cucox.me` → DNS records that the
two new CNAMEs appear, both **orange-clouded (proxied)**, both pointing
at `<TUNNEL_UUID>.cfargotunnel.com`.

### 3.2 — Add hostname routes to `cloudflared/config.yaml.tmpl`

The repo's `cloudflared/config.yaml.tmpl` already contains the correct
commented-out block for `cucox.me` and `www.cucox.me` (placed there in
runbook 03 § Step 5.1 as a runbook 05 hand-off). **Uncomment that
block.** The block lands above the catch-all `http_status:404`:

```yaml
ingress:
  - hostname: cucox.me
    service: https://10.10.20.50:443
    originRequest:
      noTLSVerify: true
      httpHostHeader: cucox.me
  - hostname: www.cucox.me
    service: https://10.10.20.50:443
    originRequest:
      noTLSVerify: true
      httpHostHeader: www.cucox.me
  - service: http_status:404
```

The catch-all 404 MUST remain the last entry. cloudflared evaluates
ingress rules top-to-bottom and uses the first match.

### 3.3 — Materialize on `lab-edge01` and reload

Same materialize/validate/restart pattern as runbook 03 § Step 5.2. One
shell line per logical step (paste-fragility memo).

Materialize:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra" && sed "s/<TUNNEL_UUID>/$(cat ~/.scratch/tunnel-uuid)/" cloudflared/config.yaml.tmpl | ssh ubuntu@10.10.30.21 'sudo tee /etc/cloudflared/config.yaml >/dev/null && sudo chown cloudflared:cloudflared /etc/cloudflared/config.yaml && sudo chmod 0644 /etc/cloudflared/config.yaml'
```

Validate:

```sh
ssh ubuntu@10.10.30.21 'sudo -u cloudflared cloudflared --config /etc/cloudflared/config.yaml ingress validate'
```

Per runbook 03 § 5.2, on 2026+ cloudflared builds with this catch-all
plus two real rules, expect either `OK` (older builds) or the
`Use \`cloudflared tunnel run\` to start tunnel <UUID>` hint (2026+).
Either output indicates the config parsed; only an actual parse error
(unknown field, malformed YAML) is a real failure.

Restart cloudflared (the systemd unit has `ExecStart` only, no
`ExecReload`, so `systemctl reload` won't work):

```sh
ssh ubuntu@10.10.30.21 'sudo systemctl restart cloudflared && sleep 3 && sudo systemctl is-active cloudflared'
```

Expect `active`. The 4 active connections drop and re-establish over
~10s. Watch the journal for the re-registration:

```sh
ssh ubuntu@10.10.30.21 'sudo journalctl -fu cloudflared'
```

Expect 4 `INF Connection ... registered` lines within 15s. Ctrl-C
after observation.

Confirm in the Cloudflare dashboard → Networks → Tunnels →
`cucox-lab-prod`: Status HEALTHY, 4 connections, "Last seen" within 30s.

### Decision gate before Step 4

- [ ] `terraform plan` is clean ("No changes").
- [ ] Cloudflare DNS records page shows `cucox.me` and `www.cucox.me`
      CNAMEs pointing at `<TUNNEL_UUID>.cfargotunnel.com`, both orange
      (proxied).
- [ ] `/etc/cloudflared/config.yaml` on `lab-edge01` has the cucox.me
      and www.cucox.me ingress entries above the catch-all.
- [ ] `cloudflared ... ingress validate` parsed cleanly.
- [ ] `cloudflared` is `active`, journal shows 4 connections registered.
- [ ] Tunnel HEALTHY in dashboard with 4 connections.
- [ ] `dig +short NS cucox.me` STILL returns GoDaddy nameservers — the
      cutover has not yet happened. Public traffic still goes to Azure.

If any box is unchecked, do not advance.

---

## Step 4 — Stand up the in-cluster app + Ingress

The pilot app is the containerized resume site (Express + Vite SPA,
monorepo). Source lives in `Apps Code/Resume App Updated/my-resume-app-code/`
(gitignored from this repo; tracked in its own GitHub repo).

### 4.0 — MongoDB Atlas connectivity prep

The app reads from MongoDB Atlas at runtime via a `MONGO_URI`
connection string. The cluster pod will egress to Atlas via the home
WAN IP (NAT'd through the UCG-Max). **Atlas must allow that IP before
the pod can connect** — otherwise the pod boots, the first DB call
fails, and the app CrashLoopBackoffs.

Discover the cluster's egress IP from a debug pod (uses the same NAT
path as a real workload):

```sh
kubectl run egress-probe --rm -it --restart=Never --image=curlimages/curl -- curl -s -4 https://ifconfig.me
```

Expect a public IPv4. Note it.

In the Atlas dashboard → Network Access → IP Access List → **+ ADD IP
ADDRESS**. Add the egress IP with a comment like
`cucox-lab cluster egress (added 2026-05-02 for runbook 05)`. Save.
Atlas reflects new entries within ~1 minute.

> **Why allowlist instead of `0.0.0.0/0`?** `0.0.0.0/0` makes the cluster
> path work but also exposes the Atlas connection to every brute-force
> attempt on the internet. The threat priority memo locks app-data
> confidentiality at tier 3, behind home and cluster — but
> security-conservative posture says when there's no operational cost
> to a tighter rule, take the tighter rule.

> **Don't remove the Azure outbound IPs from the Atlas allowlist yet.**
> The Azure App Service still needs them while the old host serves
> traffic during the propagation window. Old IPs come out in Step 7.

Verify connectivity from a debug pod with the actual `MONGO_URI`. The
URI is decrypted into a local shell variable, passed to `kubectl run`
as a positional arg (where the local shell expands `"$URI"` once into
the kubectl command line), and then `unset` immediately afterward. The
leading-space prefix on the line skips it from shell history per
`HIST_IGNORE_SPACE` / `HISTCONTROL=ignorespace`.

```sh
 URI=$(sops --decrypt "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/ansible/group_vars/cucox_me/secrets.enc.yaml" | yq -r .mongo_uri) && kubectl run mongo-probe --rm -it --restart=Never --image=mongo:7 --command -- mongosh "$URI" --eval 'db.runCommand({ping:1})' ; unset URI
```

> **Why this shape and not `xargs -I{}`**: an earlier draft tried to
> pipe the decrypted URI through `xargs` and reference `"$URI"` in the
> mongosh args, but `xargs -I{}` only substitutes `{}`, and the literal
> `"$URI"` is then expanded by the LOCAL shell (where URI is unset) →
> empty target → mongosh hangs or errors. Setting URI as a local var
> and referencing it in the kubectl run line lets the local shell
> expand it once when constructing the kubectl command, so the pod
> actually receives the URI as an argv positional. The `--command`
> flag tells kubectl to override the `mongo:7` image's default
> entrypoint (which would otherwise launch `mongod`).
>
> **Note on URI exposure surface**: the URI lives briefly in the pod
> spec's command args (visible to anyone with read on pods/<probe-pod>
> in the cluster, until `--rm` deletes the pod on exit) and in the
> local shell's environment (until `unset`). For a single-operator
> personal lab this is acceptable; production-grade probes would
> create a Secret first and mount it via env, but that's overkill for
> a one-shot connectivity check.

Expect `{ ok: 1 }`. If it hangs ~10s with no output, the Atlas
allowlist hasn't propagated yet (refresh the IP Access List in the
Atlas dashboard and confirm `ACTIVE`); re-run after confirming.
If mongosh errors with `MongoNetworkError` or `Authentication failed`,
the URI itself has a problem (wrong cluster, expired credentials)
— re-fetch from the Azure portal and re-seal Step 4.1 before
re-running.

If running Step 4.0 before 4.1 (e.g. for an early connectivity
check), the simpler shape — paste the URI inline — also works:

```sh
 URI='<paste-mongo-uri-here>' && kubectl run mongo-probe --rm -it --restart=Never --image=mongo:7 --command -- mongosh "$URI" --eval 'db.runCommand({ping:1})' ; unset URI
```

Same leading-space prefix; same `unset` cleanup.

### Decision gate before Step 4.1

- [ ] Egress IP discovered and noted.
- [ ] Atlas IP Access List contains that IP.
- [ ] `mongo-probe` returned `{ ok: 1 }` from the cluster.

### 4.1 — SOPS-seal `MONGO_URI` and `JWT_SECRET`

Two real app secrets — the Mongo connection string (which embeds DB
credentials) and the JWT signing secret used by the auth controller.
Both follow the same SOPS pattern as runbook 03's tunnel creds; nothing
plaintext on disk.

The current values can be read from the Azure portal at
**App Services → CucoxResumeApp → Settings → Environment variables**
(click "Show value" on each). For `JWT_SECRET`, this is also a good
moment to **rotate it** (generate a new random value) — old tokens
issued by the Azure host will be invalidated, but the resume site has
no long-lived sessions worth preserving across the cutover, and JWT
rotation is cheap.

Create the file via SOPS streaming so the plaintext never lands on
disk:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra" && mkdir -p ansible/group_vars/cucox_me
```

```sh
printf 'mongo_uri: %s\njwt_secret: %s\n' '<paste-mongo-uri-here>' '<paste-or-generate-jwt-secret>' | sops --encrypt --filename-override ansible/group_vars/cucox_me/secrets.enc.yaml --input-type yaml --output-type yaml /dev/stdin > "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/ansible/group_vars/cucox_me/secrets.enc.yaml"
```

Verify the sealed file is non-empty and contains a sops metadata
block:

```sh
head -3 "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/ansible/group_vars/cucox_me/secrets.enc.yaml" && wc -c "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/ansible/group_vars/cucox_me/secrets.enc.yaml"
```

If `wc -c` shows 0, re-check `.sops.yaml`'s `*.enc.yaml` rule (added in
runbook 03 § 1.3); without it, sops fails silently and the `>` redirect
leaves an empty file.

### 4.2 — Build and push the container image to GHCR

The Dockerfile lives in the **app repo** (not this infra repo) at
`Apps Code/Resume App Updated/my-resume-app-code/Dockerfile`. It is a
multi-stage build:

- Stage 1: `node:22-alpine` builds the Vite client (`npm ci && npm run build`)
  with `VITE_BACKEND_URL` left empty → relative URLs → same-origin.
- Stage 2: `node:22-alpine` builds the TypeScript server (`npm ci && npm run build`),
  then copies the client's `dist/` into `dist/public/` so the runtime
  Express app's `express.static(path.join(__dirname, "public"))` finds it.
- Stage 3: `node:22-alpine` runtime, prod-only deps (`npm ci --omit=dev`),
  `EXPOSE 5001`, runs as the non-root `node` user, `CMD ["node", "dist/server.js"]`.

A `.dockerignore` excludes `node_modules/`, `dist/`, `.git/`, `.github/`,
`.env*`, `.DS_Store`, and various editor cruft so the build context
stays small.

Authenticate to GHCR with a GitHub PAT scoped to `write:packages` (one
PAT per operator; rotate calendar reminder at 90 days). Login with the
PAT on stdin to keep it out of shell history:

```sh
gh auth token > /tmp/ghcr.pat && cat /tmp/ghcr.pat | docker login ghcr.io -u Cucox91 --password-stdin && rm -P /tmp/ghcr.pat
```

> The `gh auth token` step assumes the GitHub CLI is logged in with a
> token that has `write:packages`. If not, generate a classic PAT in
> GitHub → Settings → Developer settings → Personal access tokens →
> Tokens (classic) with `write:packages` + `read:packages` scopes,
> paste it interactively into the `docker login` prompt.

Build and push (one-liner per paste-fragility memo). Tag with both a
unique version (e.g. `0.1.0` or a date) AND `latest`; the unique tag is
what the cluster Deployment references for reproducibility, `latest`
is for human convenience.

Two `docker build` flags are load-bearing here:

- **`--platform=linux/amd64`** — the Mac Air is Apple Silicon (arm64);
  the k3s cluster runs on the Ryzen workstation (amd64). Without an
  explicit platform, BuildKit produces an arm64-only image and the
  cluster's `kubelet` rejects it on pull (`no matching manifest for
  linux/amd64`). Phase 5 will add `lab-arm01`/`02` ARM workers; at that
  point we move to a multi-arch build (`--platform=linux/amd64,linux/arm64`).
- **`--provenance=false`** — BuildKit's default attaches SLSA provenance
  attestations to the manifest. GHCR has a long-standing 500-error bug
  accepting these on first push to a new package namespace
  (`failed commit on ref "manifest-sha256:..." ... 500 Internal Server
  Error`). Disabling provenance produces a clean single-platform manifest
  that GHCR accepts. We can revisit attestations once GHCR fixes the bug
  and/or once we move to a self-hosted registry in Phase 4.

Build:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/Apps Code/Resume App Updated/my-resume-app-code" && docker build --provenance=false --platform=linux/amd64 -t ghcr.io/cucox91/my-resume-app:0.1.0 -t ghcr.io/cucox91/my-resume-app:latest .
```

Push (separate command — first push uploads layers, second tag is a
near-instant ref add):

```sh
docker push ghcr.io/cucox91/my-resume-app:0.1.0 && docker push ghcr.io/cucox91/my-resume-app:latest
```

After the first push, **make the package public** so the cluster can
pull anonymously (no `imagePullSecrets` needed):

GitHub → your profile → Packages → `my-resume-app` → **Package
settings** → Danger Zone → **Change package visibility** → **Public**.
Confirm.

> **Why public?** The app source repo is already public. The image
> contents are public-equivalent, so making it private adds no
> information advantage and *does* add a credential-rotation surface
> in the cluster. Public image collapses the auth complexity to zero.

Verify the image is pullable from the cluster:

```sh
kubectl run pull-probe --rm -it --restart=Never --image=ghcr.io/cucox91/my-resume-app:0.1.0 -- node --version
```

Expect `v22.x.x`. If pull fails with `unauthorized`, the package is
still private — re-do the visibility step.

### 4.3 — Apply the k8s manifests

Five manifests under `k8s/apps/cucox-me/`:

**`k8s/apps/cucox-me/00-namespace.yaml`** — namespace with PSA
`restricted` + `restricted` warn:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cucox-me
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

**`k8s/apps/cucox-me/10-configmap.yaml`** — non-secret env vars:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cucox-me-config
  namespace: cucox-me
data:
  CLIENT_URL: "https://cucox.me"
  PORT: "5001"
  # SEED_DATA intentionally NOT set — would trigger the seeder on
  # every pod start. If a one-time seed is needed, run a separate Job.
```

**Secret applied via SOPS-stream (no manifest committed).** From the
Mac Air:

```sh
sops --decrypt "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/ansible/group_vars/cucox_me/secrets.enc.yaml" | yq '{apiVersion: "v1", kind: "Secret", metadata: {name: "cucox-me-secrets", namespace: "cucox-me"}, type: "Opaque", stringData: {MONGO_URI: .mongo_uri, JWT_SECRET: .jwt_secret}}' | kubectl apply -f -
```

The plaintext exists only in pipe memory; nothing lands on disk.
Verify:

```sh
kubectl -n cucox-me get secret cucox-me-secrets -o jsonpath='{.data.MONGO_URI}' | base64 -d | head -c 30; echo
```

Expect the first 30 chars of the URI (e.g. `mongodb+srv://...`).

**`k8s/apps/cucox-me/20-deployment.yaml`** — the Express app:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cucox-me-web
  namespace: cucox-me
  labels:
    app.kubernetes.io/name: cucox-me-web
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: cucox-me-web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: cucox-me-web
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: ghcr.io/cucox91/my-resume-app:0.1.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 5001
              protocol: TCP
          envFrom:
            - configMapRef:
                name: cucox-me-config
            - secretRef:
                name: cucox-me-secrets
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /
              port: 5001
            initialDelaySeconds: 15
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /
              port: 5001
            initialDelaySeconds: 5
            periodSeconds: 10
```

> **`readOnlyRootFilesystem: true`** — Express + the static file mount
> don't write anywhere. If a future feature needs scratch space, mount
> an `emptyDir` at `/tmp` rather than relaxing this.

> **`automountServiceAccountToken: false`** — the resume app does not
> talk to the Kubernetes API. Default-deny posture.

**`k8s/apps/cucox-me/30-service.yaml`**:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: cucox-me-web
  namespace: cucox-me
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: cucox-me-web
  ports:
    - name: http
      port: 80
      targetPort: 5001
      protocol: TCP
```

**`k8s/apps/cucox-me/40-ingress.yaml`**:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cucox-me
  namespace: cucox-me
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: cucox.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cucox-me-web
                port:
                  number: 80
    - host: www.cucox.me
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cucox-me-web
                port:
                  number: 80
```

> **Why `ssl-redirect: "false"`?** TLS terminates at Cloudflare's edge.
> cloudflared talks HTTPS to ingress-nginx with `noTLSVerify: true`
> (per ADR-0014, until cert-manager lands in Phase 3), and ingress-nginx
> serves HTTP to the backend pod. Forcing ssl-redirect would make
> cloudflared's request to ingress get a 308 back to itself; disabling
> it lets the chain work end-to-end.

Apply (in order — namespace first):

```sh
kubectl apply -f "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/k8s/apps/cucox-me/00-namespace.yaml" && kubectl apply -f "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/k8s/apps/cucox-me/10-configmap.yaml"
```

Apply the Secret via the SOPS-stream one-liner from above (NOT a
committed manifest).

Then the rest:

```sh
kubectl apply -f "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/k8s/apps/cucox-me/20-deployment.yaml" && kubectl apply -f "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/k8s/apps/cucox-me/30-service.yaml" && kubectl apply -f "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/k8s/apps/cucox-me/40-ingress.yaml"
```

### 4.4 — Verify the pod is healthy

```sh
kubectl -n cucox-me get pods -w
```

Expect a single pod transitioning `Pending` → `ContainerCreating` →
`Running` → `Ready 1/1`. Ctrl-C once Ready.

Tail the pod logs:

```sh
kubectl -n cucox-me logs deploy/cucox-me-web --tail=50
```

Expect:

```
Server running on port 5001
MongoDB connected
```

If `MongoDB connection error:`, re-check Step 4.0 (Atlas allowlist
contains the cluster egress IP) and Step 4.1 (`MONGO_URI` decrypts to
the correct value — `kubectl -n cucox-me get secret cucox-me-secrets
-o jsonpath='{.data.MONGO_URI}' | base64 -d` to spot-check without
echoing the full URI).

If the pod is stuck Pending, `kubectl -n cucox-me describe pod
<pod-name>` and look at Events — most likely a PSA `restricted`
violation on something the manifest didn't explicitly set
(e.g. missing `runAsNonRoot`).

### 4.5 — Pre-cutover smoke test through the cluster path

The new path is up but no public DNS resolves to it. Test the path
end-to-end **before** changing nameservers, by using `--resolve` to
bypass DNS and force curl through ingress-nginx with the right Host
header.

Static page (the SPA shell):

```sh
curl -k -sI --max-time 5 --resolve cucox.me:443:10.10.20.50 https://cucox.me/
```

Expect `HTTP/2 200`. The TLS certificate will be ingress-nginx's
self-signed (the `-k` is what ignores it); cloudflared uses
`noTLSVerify: true` so the same insecure handshake works in production
until cert-manager lands.

Static page content:

```sh
curl -k -s --max-time 5 --resolve cucox.me:443:10.10.20.50 https://cucox.me/ | grep -E '<title>|<div id="root"' | head -3
```

Expect HTML containing the Vite SPA shell.

API endpoint:

```sh
curl -k -sI --max-time 5 --resolve cucox.me:443:10.10.20.50 https://cucox.me/api/experiences
```

Expect `HTTP/2 200` (or `204` for an empty list if the DB has no
experiences yet — both indicate the route is live and Mongo is
reachable). `502` or `504` means the pod is up but Mongo isn't
reachable; `404` means the Ingress isn't routing `/api` to the pod.

`www` flavor:

```sh
curl -k -sI --max-time 5 --resolve www.cucox.me:443:10.10.20.50 https://www.cucox.me/
```

Same `HTTP/2 200`. The Ingress has both hosts; both resolve to the
same Service.

### Decision gate before Step 5

- [ ] `kubectl -n cucox-me get pods` shows `1/1 Running` for
      `cucox-me-web-*`.
- [ ] Pod logs show both `Server running on port 5001` and
      `MongoDB connected`.
- [ ] Static-page curl via `--resolve` returns `HTTP/2 200` and HTML
      containing the SPA shell, for both `cucox.me` and `www.cucox.me`.
- [ ] API curl via `--resolve` to `https://cucox.me/api/experiences`
      returns `HTTP/2 200` (or `204` if empty).
- [ ] `dig +short NS cucox.me` STILL returns GoDaddy. The cutover has
      NOT happened.

If any box is unchecked, do not advance. Step 5 is the irreversible-ish
gate.

---

## Step 5 — Cutover: change nameservers at GoDaddy

This is the moment of truth. **Until you complete this step, no public
visitor sees Cloudflare for this zone — you can back out everything
above with no impact.**

### 5.0 — Pre-cutover prep

Three small steps that make rollback mechanical and shorten the
propagation tail:

**Screenshot the current GoDaddy NS values.** Log into GoDaddy → Domain
Portfolio → `cucox.me` → DNS → Nameservers. Take a screenshot of the
current values (e.g. `ns57.domaincontrol.com` / `ns58.domaincontrol.com`).
Save it next to the GoDaddy zone baseline:

```sh
mkdir -p ~/Documents/cucox-lab-archive/zone-baselines/cucox.me-ns-screenshots
mv ~/Downloads/Screenshot*.png ~/Documents/cucox-lab-archive/zone-baselines/cucox.me-ns-screenshots/godaddy-ns-pre-cutover-$(date +%Y-%m-%d).png
```

This is your literal rollback source: if the cutover goes wrong, you
read the GoDaddy nameservers off this screenshot and paste them back
into GoDaddy. Don't rely on memory.

**Drop record TTLs as low as GoDaddy will allow, ~24 hours before the
planned cutover.** At GoDaddy, edit each record (apex A, www CNAME, any
TXT records you'll need to change later) and set TTL to 300s if your
plan allows it; otherwise 600s.

> **GoDaddy minimum-TTL constraint (lesson learned during the 2026-05-02
> cucox.me run):** GoDaddy enforces a 600-second minimum TTL on
> personal/Basic plans across most TLDs (`.me`, `.com`, etc.). Premium /
> Pro / Reseller tiers allow lower values. If the GoDaddy UI rejects 300
> with "minimum value is 600", accept 600 — the remaining cutover-tail
> concern is dominated by the parent zone's NS-record TTL
> (registry-controlled, not editable at our layer) rather than by our
> record-level TTLs. The difference between 600 and 300 changes the
> record-cache tail by seconds, not minutes.

This doesn't affect current behavior; it just shortens how long stale
resolvers cache the *old* values once the cutover starts. Existing TTLs
of 600–3600s mean a propagation tail of up to ~1 hour for record-level
caching; with 600s TTLs across the board, ~10 minutes for that
secondary factor. The dominant factor — parent NS TTL — remains the
same regardless.

> Per 05a § Pre-cutover actions, this is "informational, not required" —
> but for a security-conservative rollback posture, doing it is cheap
> and tightens the recovery window if anything goes wrong.

**Decide cutover timing.** Pick a window when:
- You can dedicate the next ~30 minutes to monitoring.
- The dashboards (runbook 04) are accessible from your current network.
- You're not also juggling another change.

For `cucox.me` specifically (resume site, low traffic, no email): any
reasonable window works. For zones with email or higher traffic, prefer
a low-traffic window.

### Decision gate before Step 5.1

- [ ] Screenshot of current GoDaddy NS values saved at
      `~/Documents/cucox-lab-archive/zone-baselines/cucox.me-ns-screenshots/`.
- [ ] (Optional but recommended) GoDaddy record TTLs set to 300s at
      least 24 hours before cutover.
- [ ] All Step 4 boxes still hold (run a quick re-check of the curl
      `--resolve` smoke test from Step 4.5).
- [ ] Atlas IP allowlist still contains the cluster egress IP.
- [ ] You're committed to the next ~30 minutes of active monitoring.

### 5.1 — Change nameservers at GoDaddy

1. GoDaddy → Domain Portfolio → `cucox.me` → DNS → Nameservers →
   "Change Nameservers" → "Enter my own nameservers (advanced)".
2. Enter the two Cloudflare nameservers (saved in scratch notes during
   runbook 03 § Step 2.0.2).
3. Save.
4. Cloudflare detects the change within minutes-to-hours and flips the
   zone status to **Active** in the Cloudflare dashboard.

### Immediately after the NS change — force Cloudflare verification

**Click "Check nameservers now" on the Cloudflare dashboard** (Websites
→ `<zone>` → Overview, in the "Waiting for your registrar to propagate
your new nameservers" panel). Cloudflare's automatic verification cron
runs periodically (every 30-60 min) and can lag the actual registry
delegation by hours.

> **Why this matters (lesson learned during the 2026-05-02 cucox.me
> run):** Cloudflare's apex CNAME flattening is **gated on zone Active
> status**. While the zone is Pending, the apex CNAME exists in
> Cloudflare's database but is **not flattened or served** by
> Cloudflare's authoritative nameservers. `dig <zone> @<cloudflare-ns>`
> returns `NOERROR / ANSWER 0 / SOA in authority` — i.e. NODATA, which
> browsers surface as a generic DNS resolution error (Chrome shows
> `DNS_PROBE_FINISHED_NXDOMAIN`). Non-apex CNAMEs like `www` work fine
> in Pending state because they don't need flattening. So you'd see a
> partially-broken zone — www serves correctly, apex doesn't —
> potentially for hours, until Cloudflare's cron catches up.
>
> Force the verification immediately to skip that window. Within
> seconds of clicking, the badge flips to "Your domain is now
> protected by Cloudflare" / Active, and apex CNAME flattening kicks
> in immediately. `dig <zone> @1.1.1.1` then returns Cloudflare anycast
> A records (`104.21.x.y`, `172.67.x.y`).

### Propagation behavior

- Most resolvers see the new NS within 1–4 hours.
- Some ISPs cache NS records for the full TTL of the parent zone (often
  24 hours, can be 48). During this window:
  - Some visitors resolve via Cloudflare → Tunnel → cluster (new path).
  - Some visitors resolve via GoDaddy → old A record → old App Service
    (old path).
- **Both paths must work correctly** for the entire propagation window.
  Do not tear down the old host until propagation is complete *and*
  the per-zone Open Questions checklist is resolved.

### Local-resolver lag on the operator workstation

After the NS change, your Mac may continue to fail to resolve `<zone>`
for the next ~10-15 minutes even though public resolvers (1.1.1.1 /
8.8.8.8 / 9.9.9.9) have already flipped. The negative cache lives on
whatever DNS forwarder the Mac talks to (the UCG-Max gateway on
`CucoxLab-Mgmt` SSID, which forwards to upstream resolvers). The Mac's
own `mDNSResponder` cache flush (`sudo dscacheutil -flushcache &&
sudo killall -HUP mDNSResponder`) does NOT reach into the UCG-Max's
cache. The negative-cache TTL on the SOA (typically 1800s but counts
down from the moment cached) governs when the UCG-Max will re-query.

This is purely an operator-experience issue — public visitors using
their own ISP resolvers are unaffected. Verify the path is working via
`curl --resolve <zone>:443:<cloudflare-anycast-ip>` until your local
resolver catches up.

### Monitoring propagation

```sh
dig @1.1.1.1   +short NS cucox.me
```

```sh
dig @8.8.8.8   +short NS cucox.me
```

```sh
dig @9.9.9.9   +short NS cucox.me
```

```sh
dig @1.1.1.1   +short cucox.me
```

External validators (open in a browser):

- `https://dnschecker.org/#NS/cucox.me` — global NS propagation.
- `https://www.whatsmydns.net/#A/cucox.me` — global A/CNAME propagation.

---

## Step 6 — Validation

Run these checks within the first hour after NS change, then again at
+6h, +24h, +48h.

### 6.1 — Web reachability

After your local resolver flips:

```sh
curl -I --max-time 5 https://cucox.me/
```

```sh
curl -I --max-time 5 https://www.cucox.me/
```

Expected: `HTTP/2 200` (or 301/302 to the canonical host). The TLS
certificate should be issued by Cloudflare (`issuer = Cloudflare Inc
ECC CA-3` or similar — check with `curl -vI` if needed).

If your local resolver hasn't flipped yet (TTL caching at your ISP),
exercise the new path explicitly with `--resolve` to a Cloudflare edge
IP. Find one:

```sh
dig @1.1.1.1 +short cucox.me | head -1
```

Then:

```sh
curl -I --max-time 5 --resolve cucox.me:443:<that-cloudflare-ip> https://cucox.me/
```

Expect `Server: cloudflare` in the response headers.

### 6.2 — API reachability

The frontend is same-origin via relative paths, so an API hit through
the new path is the strongest end-to-end check:

```sh
curl -I --max-time 5 https://cucox.me/api/experiences
```

Expect `HTTP/2 200` (or `204`). `502`/`504` means cloudflared can't
reach ingress or ingress can't reach the pod (recheck Step 3.3 + Step
4.4); `503` from Cloudflare means the Tunnel is offline.

### 6.3 — Email reachability

> **For `cucox.me`: skip this section.** Per 05a § Record inventory,
> there are no MX records on cucox.me — there is no email
> infrastructure to break. Email-disruption risk: zero.
>
> **For zones that DO have MX records (`exycle.com`, `cucoxcorp.com`):**
> follow this section.

```sh
dig +short MX <zone>
```

Compare to Step 1 export — must match.

Send a **test email TO** an address at the zone from an external
account (Gmail, etc.). It should arrive normally. Check the headers on
receipt to confirm the `Received:` chain looks right.

If you also send email **FROM** addresses at this zone, send one and
inspect the headers on the receiving side: SPF should be `pass`, DKIM
should be `pass`, DMARC alignment should be intact. Use
[mail-tester.com](https://www.mail-tester.com/) for a rapid 0–10 score.

### 6.4 — Watch with the runbook 04 dashboards

Open Grafana on the Mac Air at `https://grafana.lab.cucox.local/` (the
host resolves via `/etc/hosts` to `10.10.20.50` per runbook 04 § 7.1).
Three views to keep open during the propagation window:

**Cucox Lab → Cluster overview** — node CPU/RAM/network. Resume site is
low-volume traffic; any spike during propagation means something else
is going on. Baseline before propagation, watch deltas.

**Cucox Lab → Workload per-namespace**, namespace dropdown set to
`cucox-me` — pod restart count must stay 0; CPU/memory should be
near-idle. Container restarts during propagation usually mean a Mongo
connection drop (Atlas allowlist or transient network).

**Prometheus / Explore**, paste these queries one at a time:

- `cloudflared_tunnel_total_requests{tunnel="cucox-lab-prod"}` —
  cumulative requests through the tunnel. Should start incrementing
  once the first resolver flips. Verify metric name against the live
  endpoint at runbook 04 § 6 if needed:
  `ssh ubuntu@10.10.30.21 'curl -s http://10.10.30.21:2000/metrics | grep ^cloudflared_tunnel_'`.
- `cloudflared_tunnel_active_streams{tunnel="cucox-lab-prod"}` —
  in-flight streams. Spikes correlate with traffic bursts.
- `nginx_ingress_controller_requests{exported_namespace="cucox-me"}` —
  the inside-the-cluster view of requests reaching the cucox-me
  Ingress. Should start non-zero once the first cluster-routed visitor
  arrives.

### 6.5 — Cloudflare zone health

In Cloudflare → DNS Analytics, verify queries are arriving for
`cucox.me`. In Tunnels → `cucox-lab-prod`, verify the Tunnel is healthy
and serving the new hostnames.

### Decision gate before Step 7

- [ ] All five `dig` propagation checks return Cloudflare nameservers.
- [ ] dnschecker.org shows >95% global NS propagation.
- [ ] Web + API curls succeed at +1h, +6h, +24h, and +48h.
- [ ] No pod restarts in `cucox-me` namespace during the entire
      propagation window.
- [ ] Cloudflare DNS Analytics shows steady query volume on the new
      zone.
- [ ] (For zones with email) MX unchanged + test mail flowed both ways.
- [ ] Per-zone Open Questions checklist (05a § Open questions) is
      fully resolved.

If any box is unchecked, do NOT advance to Step 7. Old host stays up.

---

## Step 7 — Tear down the old host

**Gate:** all of Step 6's decision gate must hold, AND 48 hours must
have elapsed since the NS change.

The teardown shape depends on what kind of "old host" we're retiring.
Two flavors:

### 7.A — Old host is a managed PaaS (Azure App Service, Azure Static Web Apps, Vercel, Netlify, etc.)

> **For `cucox.me`:** this is the relevant flavor. Old host is the
> Azure App Service Web App `CucoxResumeApp` in resource group
> `Single_Pages`, subscription `Single Pages`, region East US 2.

1. **Confirm the source of truth is in Git.** For Azure App Service +
   GH Actions deploy: confirm the latest deploy was from the `main`
   branch HEAD (`git log -1 main` matches the SHA in the App Service's
   Deployment Logs at the time of last successful deploy). For
   `cucox.me`: last Azure deploy was 2026-04-18 per the portal; verify
   the cluster image is built from a commit at-or-after that SHA.

2. **Revoke the Azure publish profile credential** in the GH Actions
   side: GitHub → `Cucox91/my-resume-app` → Settings → Secrets and
   variables → Actions → `AZURE_WEBAPP_PUBLISH_PROFILE` → Remove. This
   ensures the workflow can't accidentally redeploy to Azure even if
   the App Service is somehow recreated. Optionally also retire
   `.github/workflows/azure-deploy.yml` in favor of a future GHCR-push
   workflow (Phase 3 ergonomic, not strictly Step 7 scope).

3. **Remove the Azure outbound IPs from the MongoDB Atlas allowlist.**
   They were left in place during the propagation window; once the App
   Service is no longer serving, those entries are pure attack surface.
   Atlas → Network Access → IP Access List → delete each Azure outbound
   IP from the original CucoxResumeApp Networking panel
   (`9.169.238.213`, `9.169.239.30`, etc. — capture the full list from
   the Azure portal before deleting). Keep the cluster egress IP.

4. **Stop the Azure Web App** (reversible) before deleting:
   Portal → CucoxResumeApp → Stop. Wait 24 hours; if no one complains,
   proceed to delete. The App Service Plan continues to bill while
   stopped — see step 6 for full plan removal.

5. **Confirm Application Insights state.** App Insights for
   `CucoxResumeApp` continues collecting telemetry as long as the app
   runs and the connection string env var is set. Once the App Service
   is stopped, telemetry naturally goes to zero. Decide: delete the App
   Insights resource immediately (loses historical telemetry), or park
   it for 90 days (still costs negligible storage) and delete later.
   For a resume site: delete immediately is fine.

6. **Delete the Azure App Service + App Service Plan + App Insights**
   in the portal. The App Service Plan billing only stops when the
   Plan resource itself is deleted — stopping the Web App alone keeps
   the plan billable. Confirm in Cost Management afterward.

7. **Resolve the per-zone DNS records that pointed at the old host.**
   For `cucox.me`:
   - TXT `@ "_gaiibn..."` — App Service domain validation. After App
     Service deletion, this record is meaningless. Delete via Cloudflare
     dashboard (or add a `cloudflare_record` resource with a Terraform
     destroy in the next plan).
   - TXT `asuid` — same: App Service validation. Delete after deletion.
   - CNAME `_domainconnect` (if Cloudflare auto-imported it) —
     GoDaddy-proprietary, no function on Cloudflare. Delete.
   - The orphan `www` CNAME pointing at `lemon-mud-0d596dd0f.6.azurestaticapps.net.`
     was already replaced by Terraform in Step 3.1; no action.

8. **Final accounting backup.** Save into
   `~/Documents/cucox-lab-archive/migration-archive/cucox-me-2026-05-XX/`:
   the App Service publish profile (now revoked but useful as forensic
   evidence of the configuration), screenshots of the App Service
   essentials and env vars, the App Service Plan invoice line item from
   the last billing period, and the Azure resource IDs.

### 7.B — Old host is a self-hosted server (VPS, VM, bare metal)

(Reusable template for future zones if any of them migrate from a real
server.)

1. **Take a final backup**: site files, database dumps, TLS
   certificates, server configs, cron entries, application logs from
   the last 30 days. Store in
   `~/Documents/cucox-lab-archive/migration-archive/<zone>-<date>/` or
   your offsite backup of choice. (When the second NVMe lands and the
   `tank` pool exists per ADR-0011, this path migrates to
   `tank/bench/migration-archive/` and gets recorded in a follow-up
   ADR.)
2. **Power down or terminate the old host.**
3. **Cancel any standalone TLS certificates** issued for this zone on
   the old host (Cloudflare now handles edge TLS; your origin uses
   self-signed or internal certs).
4. **Cancel any external CDN, WAF, or "site-monitoring" service** tied
   to the old host that's no longer needed.
5. **Remove old host references** from any inventory / monitoring /
   docs.

### 7.C — Path correction for the migration archive

Any prior wording in earlier runbook drafts that referenced
`tank/bench/migration-archive/` is incorrect during Phase 1. Per
ADR-0011, the `tank` pool is deferred. The current migration-archive
home is `~/Documents/cucox-lab-archive/migration-archive/` on the Mac
Air. When ADR-0011 closes (second NVMe + `tank` pool created), an ADR
will document the path migration.

---

## Rollback

The right rollback depends on *when* you discover a problem.

### During propagation (NS change made, < 48h, old host still alive)

- **Fastest path:** at GoDaddy, change nameservers back to the GoDaddy
  defaults from your Step 5.0 screenshot. Most resolvers resume
  answering from the old DNS within minutes-to-hours; some ISPs still
  serve the cached Cloudflare NS for up to 48h.
- **Tactical patch:** in Cloudflare, flip the offending records back to
  point at the old host's IP/hostname (orange cloud → grey cloud,
  value → old A record). Effective for visitors already resolving via
  the Cloudflare NS.

### After propagation, before old-host teardown

- Same as above. Old host is still the safety net.

### After old-host teardown (Step 7 done)

- Reverting at GoDaddy buys nothing — the old host is gone.
- Recovery is fix-forward in the cluster + Cloudflare. Common scenarios:
  - Cluster app down → `kubectl` debug, scale, restart.
  - `cloudflared` down → restart on `lab-edge01`, check Tunnel status.
  - DNS record wrong → fix in Cloudflare, propagation is fast (minutes,
    because TTLs on Cloudflare are short).
- This is *exactly why* Step 7 has the 48-hour + Open-Questions gate.
  Resist the temptation to tear down the old host the same day.

---

## Per-zone tracking

| Zone | Status | NS-changed-at | Old-host-decommissioned-at | Notes |
|---|---|---|---|---|
| `cucox.me` | in-progress | — | — | Phase 2 pilot |
| `exycle.com` | planned | — | — | Phase 3 |
| `cucoxcorp.com` | planned | — | — | Phase 3, last (highest stakes) |

Update this table in-place as each migration completes. It's the
operational source of truth for "which domains are where".

---

## Next domain

Repeat Steps 1–7 for the next zone. Each migration is independent — they
do not need to be done in lockstep, and you should leave at least 48
hours between migrations so the previous one's propagation tail is
finished before you take on a new failure surface.

When all three initial domains are migrated, the
`cloudflared/config.yaml` matches the canonical example in
`ARCHITECTURE.md` § 6.3.
