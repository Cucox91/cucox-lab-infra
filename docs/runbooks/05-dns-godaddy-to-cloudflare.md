# Runbook 05 — DNS Migration: GoDaddy → Cloudflare

> **Goal:** Move authoritative DNS for one zone from GoDaddy to Cloudflare
> with **zero downtime for the website and zero email disruption**, enabling
> that zone's hostnames to be served via the Cloudflare Tunnel into the lab.
>
> **Example zone in this runbook:** `cucox.me`. Repeat the procedure
> per-domain. `cucox.me` is the Phase 2 pilot; `exycle.com` and
> `cucoxcorp.com` follow in Phase 3.
>
> **Estimated time:** ~30 minutes of active work, plus 1–48 hours of NS
> propagation that does not block other tasks.

---

## Prerequisites

- Cloudflare account exists (free plan is sufficient).
- Phase 0 + Phase 1 + Phase 2 cluster bring-up complete. Specifically:
  - `lab-edge01` is running with `cloudflared` connected to a Tunnel
    named `cucox-lab-prod`.
  - `ingress-nginx` is running in the cluster behind a MetalLB VIP.
  - Outbound 443/7844 is allowed from `dmz` to the internet.
- GoDaddy admin access for the zone being migrated.
- A scoped Cloudflare API token with `Zone:DNS:Edit` for this zone (used
  by Terraform under `terraform/cloudflare/`).
- An app to put behind the new hostname — for the pilot this is the
  containerized cucox.me resume site, deployed to namespace `cucox-me`.

---

## Scope of one migration

For a single zone (`cucox.me`), the migration touches:

1. Inventory of existing DNS at GoDaddy.
2. Cloudflare zone creation + record import + verification.
3. Tunnel CNAMEs + `cloudflared` ingress rules.
4. In-cluster app deployment + `Ingress` resource.
5. Cutover (the GoDaddy nameserver change).
6. Validation (web + email + propagation monitoring).
7. Old-host teardown (gated on validation).

---

## Step 1 — Inventory existing DNS at GoDaddy

In the GoDaddy DNS dashboard for `cucox.me`, capture every record:

- **A / AAAA** — typically the apex pointing to the current host.
- **CNAME** — `www`, `mail`, `cdn.*`, etc.
- **MX** — email mail-exchanger records. **DO NOT BREAK THESE.**
- **TXT** — SPF (`v=spf1 ...`), DKIM (`*._domainkey.*`), DMARC (`_dmarc`),
  domain-verification records (Google Search Console, Apple, Microsoft 365,
  GitHub Pages, etc.).
- **SRV** — uncommon, but check.
- **NS** at non-apex levels (delegated subdomains) — uncommon.

Record any GoDaddy-specific services in use:

- **Domain forwarding** → must be replaced with a Cloudflare Page Rule or
  Bulk Redirect.
- **GoDaddy Email / Microsoft 365 via GoDaddy** → MX + autodiscover
  records must be preserved exactly. Account billing is unaffected by the
  DNS move.
- **WHOIS privacy** → unaffected (registrar-level setting at GoDaddy).

**Save a screenshot or text export of the full zone.** You'll diff against
this after the cutover. This is non-negotiable; it's your rollback baseline.

---

## Step 2 — Create the Cloudflare zone

In the Cloudflare dashboard:

1. **Add Site → enter `cucox.me` → Free plan.**
2. Cloudflare runs an automatic record scan and pre-populates a draft of
   the zone with whatever it could resolve from public DNS.
3. **Verify every record in the draft against your Step 1 export.**
   Especially:
   - **MX records** — must match exactly, including priorities.
   - **SPF** TXT (`v=spf1 ...`) — exact match; one missing `include:` and
     legitimate mail starts going to spam.
   - **DKIM** TXT (often a long key under a selector like
     `selector1._domainkey` or `s1._domainkey`) — exact match.
   - **DMARC** TXT (`_dmarc`) — exact match including the policy and
     reporting addresses.
   - **Verification TXT** records for any IdP / SaaS that proved
     ownership of the domain.
4. For records that point to the **current external host of the website**
   — these will be replaced in Step 3, but for now leave them as in
   GoDaddy:
   - **Email-related records (MX, mail.*) → grey cloud (DNS only).**
     Cloudflare does not proxy SMTP. Email records are *always* grey.
   - **Application-related (the apex A or CNAME pointing at the old web
     host) → grey cloud for now.** You will flip these to orange and
     repoint to the Tunnel CNAME in Step 3.
5. Note the two nameservers Cloudflare assigns you:
   `ana.ns.cloudflare.com`, `chuck.ns.cloudflare.com` (yours will differ).

> **Do NOT click "Done, check nameservers" yet.** The zone is staged in
> Cloudflare but no resolver in the world is asking it for answers.

---

## Step 3 — Add the Tunnel CNAMEs and `cloudflared` ingress rules

The pattern for a Tunnel-backed hostname is:

- **Cloudflare CNAME**: `cucox.me → <TUNNEL_UUID>.cfargotunnel.com`,
  proxied (orange cloud).
- **Cloudflare CNAME**: `www.cucox.me → <TUNNEL_UUID>.cfargotunnel.com`,
  proxied.
- **`cloudflared` ingress rule** that maps each hostname to the
  in-cluster `ingress-nginx` service.

In `terraform/cloudflare/cucox-me.tf`:

```hcl
resource "cloudflare_zone" "cucox_me" {
  account_id = var.cloudflare_account_id
  zone       = "cucox.me"
  plan       = "free"
}

resource "cloudflare_record" "cucox_me_apex" {
  zone_id = cloudflare_zone.cucox_me.id
  name    = "@"
  type    = "CNAME"
  value   = "${var.tunnel_uuid}.cfargotunnel.com"
  proxied = true
  comment = "managed-by-terraform; tunnel: cucox-lab-prod"
}

resource "cloudflare_record" "cucox_me_www" {
  zone_id = cloudflare_zone.cucox_me.id
  name    = "www"
  type    = "CNAME"
  value   = "${var.tunnel_uuid}.cfargotunnel.com"
  proxied = true
}

# (Email + verification records go in cucox-me-email.tf or similar.)
```

Apply:

```sh
cd terraform/cloudflare
terraform plan -out=cucox-me.plan
terraform apply cucox-me.plan
```

Append to `cloudflared/config.yaml` (the rule file mounted into the
`cloudflared` container/service on `lab-edge01`):

```yaml
ingress:
  # ... any existing entries ABOVE this block ...
  - hostname: cucox.me
    service: https://ingress-nginx.ingress.svc.cluster.local
    originRequest:
      noTLSVerify: true
  - hostname: www.cucox.me
    service: https://ingress-nginx.ingress.svc.cluster.local
    originRequest:
      noTLSVerify: true
  # The catch-all 404 rule MUST remain the last entry:
  - service: http_status:404
```

Reload `cloudflared`:

```sh
# If running as a systemd service on lab-edge01:
ssh root@10.10.30.21 systemctl reload cloudflared

# If running in-cluster:
kubectl -n dmz rollout restart deployment/cloudflared
```

---

## Step 4 — Stand up the in-cluster app + Ingress

Create the namespace and deploy the app:

```sh
kubectl create namespace cucox-me
kubectl -n cucox-me apply -f k8s/apps/cucox-me/
```

Where `k8s/apps/cucox-me/ingress.yaml` looks like:

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

Verify the app responds *inside* the cluster before going public:

```sh
# From an operator machine with kubeconfig:
kubectl -n cucox-me get pods,svc,ingress
kubectl -n cucox-me port-forward svc/cucox-me-web 8080:80 &
curl -H 'Host: cucox.me' http://127.0.0.1:8080
# Stop the port-forward.
```

Add a unique marker to the in-cluster app — an HTML comment like
`<!-- CUCOX-LAB-CLUSTER -->` or a custom response header. This lets you
distinguish, during the propagation window, whether a given visitor's
request is being served by the new (cluster) host or the old (external)
host.

---

## Step 5 — Cutover: change nameservers at GoDaddy

This is the moment of truth. **Until you complete this step, no public
visitor sees Cloudflare for this zone — you can back out everything above
with no impact.**

1. Log in to GoDaddy → Domain Portfolio → `cucox.me` → DNS → Nameservers
   → "Change Nameservers" → "Enter my own nameservers (advanced)".
2. Enter the two Cloudflare nameservers from Step 2.
3. Save.
4. Cloudflare detects the change within minutes-to-hours and flips the
   zone status to **Active** in the Cloudflare dashboard.

### Propagation behavior

- Most resolvers see the new NS within 1–4 hours.
- Some ISPs cache NS records for the full TTL of the parent zone (often
  24 hours, can be 48). During this window:
  - Some visitors resolve via Cloudflare → Tunnel → cluster (new path).
  - Some visitors resolve via GoDaddy → old A record → old host (old path).
- **Both paths must work correctly** for the entire propagation window.
  Do not tear down the old host until propagation is complete *and*
  email is confirmed unbroken.

### Monitoring propagation

```sh
# Check the NS records as seen by major public resolvers:
dig @1.1.1.1   +short NS cucox.me
dig @8.8.8.8   +short NS cucox.me
dig @9.9.9.9   +short NS cucox.me

# Check what the apex resolves to via each:
dig @1.1.1.1   +short cucox.me
dig @8.8.8.8   +short cucox.me

# Verify MX is unchanged via each resolver:
dig @1.1.1.1   +short MX cucox.me
```

External validators (open in a browser):

- `https://dnschecker.org/#NS/cucox.me` — global NS propagation.
- `https://www.whatsmydns.net/#A/cucox.me` — global A/CNAME propagation.

---

## Step 6 — Validation

Run these checks within the first hour after NS change, then again at +6h,
+24h, +48h.

### Web reachability

```sh
curl -I https://cucox.me
curl -I https://www.cucox.me
```

Expected: HTTP 200 (or 301/302 to the canonical host). The TLS certificate
should be issued by Cloudflare (`issuer = Cloudflare Inc ECC CA-3` or
similar). If you embedded the `<!-- CUCOX-LAB-CLUSTER -->` marker in the
in-cluster app:

```sh
curl -s https://cucox.me | grep CUCOX-LAB-CLUSTER && echo "served by cluster"
```

### Email reachability

```sh
dig +short MX cucox.me      # Compare to Step 1 export — must match.
```

Send a **test email TO** an address at `cucox.me` from an external account
(Gmail, etc.). It should arrive normally. Check the headers on receipt to
confirm the `Received:` chain looks right.

If you also send email **FROM** addresses at this zone, send one and
inspect the headers on the receiving side: SPF should be `pass`, DKIM
should be `pass`, DMARC alignment should be intact. Use
[mail-tester.com](https://www.mail-tester.com/) for a rapid 0–10 score.

### Cloudflare zone health

In Cloudflare → DNS Analytics, verify queries are arriving for
`cucox.me`. In Tunnels → `cucox-lab-prod`, verify the Tunnel is healthy
and serving the new hostnames.

---

## Step 7 — Tear down the old host

**Gate:** only proceed if all of the following are true:

- 48 hours have passed since the NS change, **or** dnschecker.org shows
  >95% global propagation.
- Email has flowed through (both directions) without delivery delays for
  at least 24 hours.
- Cloudflare DNS Analytics shows steady query volume on the new zone.

Then:

1. Take a final backup of the old host: site files, database dumps, TLS
   certificates, server configs. Store in `tank/bench/migration-archive/`
   or your offsite backup.
2. Power down or terminate the old host.
3. Cancel any standalone TLS certificates issued for this zone on the old
   host (Cloudflare now handles edge TLS; your origin uses self-signed or
   internal certs).
4. Cancel any external CDN, WAF, or "site-monitoring" service tied to the
   old host that's no longer needed.
5. Remove old host references from any inventory / monitoring / docs.

---

## Rollback

The right rollback depends on *when* you discover a problem.

### During propagation (NS change made, < 48h, old host still alive)

- **Fastest path:** at GoDaddy, change nameservers back to the GoDaddy
  defaults. Most resolvers resume answering from the old DNS within
  minutes-to-hours; some ISPs still serve the cached Cloudflare NS for up
  to 48h.
- **Tactical patch:** in Cloudflare, flip the offending records back to
  point at the old host's IP/hostname (orange cloud → grey cloud, value →
  old A record). Effective for visitors already resolving via the
  Cloudflare NS.

### After propagation, before old-host teardown

- Same as above. Old host is still the safety net.

### After old-host teardown

- Reverting at GoDaddy buys nothing — the old host is gone.
- Recovery is fix-forward in the cluster + Cloudflare. Common scenarios:
  - Cluster app down → `kubectl` debug, scale, restart.
  - `cloudflared` down → restart on `lab-edge01`, check Tunnel status.
  - DNS record wrong → fix in Cloudflare, propagation is fast (minutes,
    because TTLs on Cloudflare are short).
- This is *exactly why* Step 7 has the 48-hour + email-confirmed gate.
  Resist the temptation to tear down the old host the same day.

---

## Per-zone tracking

| Zone | Status | NS-changed-at | Old-host-decommissioned-at | Notes |
|---|---|---|---|---|
| `cucox.me` | planned | — | — | Phase 2 pilot |
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

When all three initial domains are migrated, the `cloudflared/config.yaml`
matches the canonical example in `ARCHITECTURE.md` § 6.3.
