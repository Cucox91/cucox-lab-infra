# Runbook 03 — Phase 2: Cloudflared Tunnel on `lab-edge01`

> **Goal:** End the runbook with a `cloudflared` daemon running on
> `lab-edge01` (dmz VLAN), persistently connected to a Cloudflare Tunnel
> named `cucox-lab-prod`, with the in-cluster `ingress-nginx` MetalLB VIP
> (`10.10.20.50`) wired in as the upstream target. Tunnel status is
> **HEALTHY** in the Cloudflare dashboard, and the lab-edge01 → cluster
> data path is independently verified end-to-end.
>
> **No public hostnames are exposed yet.** The first publicly-reachable
> request lands in runbook 05 (DNS migration of `cucox.me`). This runbook
> stages the pipe; runbook 05 opens the valve.
>
> **Estimated time:** 90 minutes of active work, of which ~30 minutes is
> firewall preflight that this runbook refuses to compress.
>
> **Operator:** Raziel, Mac Air on `CucoxLab-Mgmt` (VLAN 10).

---

## What this runbook implements

| ARCHITECTURE.md ref | Implemented here |
|---|---|
| § 6.1 — Topology | `cloudflared` runs on `lab-edge01` (dmz VLAN), outbound-only on TCP/UDP 7844 to Cloudflare; upstream is the in-cluster ingress VIP. |
| § 6.3 — Domains & DNS | `cloudflared/config.yaml.tmpl` is materialized into `/etc/cloudflared/config.yaml` on `lab-edge01`. Hostname routes are staged but commented — runbook 05 fills them in zone-by-zone. |
| § 5.4 — Ingress / LB | `ingress-nginx` VIP `10.10.20.50` (pinned in runbook 02 § 6.1) is the only upstream cloudflared reaches. |
| § 3.3.1 — Inter-VLAN | `dmz → cluster: tcp/443 to ingress` is exercised end-to-end and verified as the only path the Tunnel needs into the cluster. |
| § 3.3.3 — Internet egress (dmz) | `tcp 80/443/7844`, `udp 7844/123` from dmz to External are verified before cloudflared is ever started. |
| § 8.1 — Tooling | `cloudflare/cloudflare` Terraform provider manages the Tunnel resource (imported after manual creation per the conservative pattern below). |
| § 9 — Secrets | Tunnel credentials JSON is SOPS-encrypted into `ansible/group_vars/lab_edge/tunnel-creds.enc.json`; Cloudflare API token lives in `terraform/cloudflare/secrets.enc.yaml`. |
| ADR-0005 | This is where ADR-0005 (Cloudflare Tunnel only, no port forwards) actually pays out. |

What this runbook does **not** do: change DNS at any registrar (runbook
05), add Cloudflare Access policies (runbook 04 § Access bootstrap),
deploy any application workload (Phase 3), or move `cloudflared` into
the cluster as a Deployment (Phase 5 future per ARCH § 6.1).

---

## Prerequisites

- **Runbook 02 complete.** `kubectl get nodes` shows 5 Ready, ingress-nginx
  serving on `10.10.20.50`. Verify from the Mac Air:

  ```sh
  curl -sI -k https://10.10.20.50/
  # Expect a response from ingress-nginx (default backend 404 is fine —
  # the connection itself is what we're proving).
  ```

  If this hangs or returns a connection error, stop. Fix runbook 02 § 6
  first; the tunnel cannot work if its upstream is unreachable from
  *any* host on cluster VLAN, never mind from dmz.

- **`lab-edge01` is up and idle.** Per runbook 01 § 4.4 it's the parked
  Ubuntu 24.04 VM at `10.10.30.21` on `dmz` (VLAN 30). Verify:

  ```sh
  ssh ubuntu@10.10.30.21 'cat /etc/os-release | grep VERSION_ID; uptime'
  # Expect: VERSION_ID="24.04"; uptime non-zero.
  ```

- **Cloudflare account exists** (free plan is sufficient for the Tunnel
  itself; Access policies in runbook 04 require a Zero Trust org, also
  free up to 50 users).
- **Mac Air has `cloudflared` CLI installed** — required for Step 2's
  tunnel creation (the new Cloudflare One UI no longer offers a
  credentials-file download from the dashboard, so locally-managed
  tunnels must be created via the CLI). Also used for ad-hoc
  `cloudflared tunnel info` / `cloudflared tunnel list` calls during
  validation. The daemon itself still runs on `lab-edge01`.

  ```sh
  brew install cloudflared
  cloudflared --version
  ```

- **Mac Air's age private key is present** at
  `~/.config/sops/age/keys.txt`. You'll encrypt the Cloudflare API
  token and the Tunnel credentials JSON with it.
- **`.sops.yaml` already matches `*.enc.yaml` and `*.enc.json`** (the
  former from runbook 02; the latter is added in Step 1.3 of this
  runbook).

---

## Scope of one Tunnel bring-up

For the single Tunnel `cucox-lab-prod`, this runbook touches:

1. Cloudflare account: scoped API token (Step 1).
2. Pending Cloudflare zone bootstrap — `cucox.me` added to Cloudflare
   without changing nameservers at GoDaddy (Step 2.0 — required to
   unblock `cloudflared tunnel login`; pulls forward runbook 05 § Step
   1 + § Step 2 partial).
3. Tunnel resource: created via `cloudflared tunnel create` from the
   Mac Air, credentials sealed into the repo, then `terraform
   import`-ed (Step 2.1–2.5 + Step 8).
4. Firewall preflight on the UCG-Max: `dmz → External` and `dmz →
   cluster` cells, plus the `dmz → Gateway` Local-In cell (Step 3).
5. `lab-edge01`: install cloudflared as a systemd service, deliver
   credentials and config (Steps 4–5).
6. Tunnel registration with Cloudflare edge (Step 6).
7. End-to-end upstream validation: cloudflared → ingress VIP (Step 7).
8. Terraform tracking of the Tunnel resource for future change control
   (Step 8).
9. Snapshot + document + commit (Step 9).

Each numbered step has an explicit **Decision gate** before the next.
Do not advance on intuition.

---

## Step 0 — Decisions to lock

Lock these values now so the rest of the runbook is mechanical.

| Variable | Value | Source |
|---|---|---|
| Tunnel name | `cucox-lab-prod` | ARCH § 10 (naming) |
| Cloudflare account | Raziel's Cloudflare account (free plan) | account-level |
| Edge VM | `lab-edge01` @ `10.10.30.21` (dmz, VLAN 30) | ARCH § 4.4 |
| Upstream target | `https://10.10.20.50:443` (ingress-nginx VIP) | ARCH § 5.4, runbook 02 § 6.1 |
| `cloudflared` version | `2024.x.x` — pin to the latest stable Debian package at install time | upstream Cloudflare |
| Auth model | **Locally-managed** tunnel — per-tunnel `<UUID>.json` credentials file on disk at `/etc/cloudflared/creds.json` (mode `0600`, owner `cloudflared:cloudflared`) | Cloudflare locally-managed Tunnels |
| Tunnel-creation order | CLI from Mac Air (`cloudflared tunnel create`) → SOPS-seal creds → `terraform import` | ADR-0007 + § "Why CLI-first, locally-managed" below |
| Account-level auth (Mac Air) | `~/.cloudflared/cert.pem` (mode `0600`), obtained once via `cloudflared tunnel login`. Account-scoped — usable for any tunnel in the account. | Cloudflare Origin Certificate |

> **Why no upstream via `https://ingress-nginx.ingress.svc.cluster.local`?**
> ARCH § 6.3's `cloudflared/config.yaml` *sketch* uses the in-cluster
> Service DNS name. That sketch assumes the Phase 5 plan from ARCH § 6.1:
> `cloudflared` running as a Deployment inside the cluster. In Phase 2
> `cloudflared` lives on `lab-edge01` (dmz VLAN, outside the cluster) and
> cannot resolve `*.svc.cluster.local`. The architectural intent — "send
> tunnel traffic to ingress-nginx" — is preserved by targeting the
> ingress VIP `10.10.20.50` directly, which is exactly the stable
> address that runbook 02 § 6.1 pinned for this purpose. When Phase 5
> moves cloudflared in-cluster, the upstream switches to the Service DNS
> name and an ADR records the transition.

> **Why CLI-first, locally-managed?** Cloudflare offers two tunnel
> patterns:
>
> - **Remotely-managed** — created in the dashboard. Ingress config and
>   hostnames live in Cloudflare's database. Connector authenticates with
>   a single install token. There is no `config.yaml` on the host and no
>   `credentials.json` to seal in the repo.
> - **Locally-managed** — created with `cloudflared tunnel create` from
>   the CLI. Config lives in `/etc/cloudflared/config.yaml` on
>   `lab-edge01`. A per-tunnel `<UUID>.json` credentials file is
>   generated locally and authenticates the connector.
>
> This runbook uses **locally-managed** because: (a) config is reviewable
> in `git` rather than in a Cloudflare-side database we can't snapshot;
> (b) disaster recovery is mechanical — sealed creds + repo's
> `config.yaml.tmpl` reconstruct the tunnel anywhere; (c) operations
> survive a Cloudflare dashboard outage. The trade-off is one extra
> step per change vs. dashboard-edit immediacy. Aligned with the
> security-conservative posture from prior phases.
>
> The new (2026) Cloudflare One UI nudges hard toward remotely-managed.
> The CLI path is the clean way to get a locally-managed tunnel; the
> dashboard is then used for verification only.

---

## Step 1 — Cloudflare account + scoped API token

The Tunnel itself does not need an API token; the daemon authenticates
with the credentials JSON. The token is for **Terraform** (Step 8) and
for runbook 05's per-zone DNS edits.

### 1.1 Create the token

Cloudflare dashboard → **My Profile → API Tokens → Create Token →
Custom Token**.

| Permission | Resource | Scope |
|---|---|---|
| Account → Cloudflare Tunnel | Edit | This account only |
| Zone → DNS | Edit | All zones in this account (runbook 05 will add zones over time) |
| Zone → Zone | Read | All zones |

Restrict by **Client IP**: only your operator IP (Mac Air home WAN IP).
Token TTL: **90 days** (calendar a rotation in `tank/bench/rotation-log/`
or your preferred reminder).

Copy the token once. There is no second viewing.

### 1.2 Verify the token works

```sh
curl -sH "Authorization: Bearer <PASTED_TOKEN>" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq .
# Expect: { "success": true, "result": { "status": "active", ... } }
```

If `success: false`, fix the token now — every Step 8 Terraform call
depends on it.

### 1.3 SOPS-seal the token into the repo

The token never lands on disk in plaintext. Same pipe-into-sops pattern
as runbook 02 § Step 1; leading-space prefix to skip shell history:

```sh
 cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
 mkdir -p terraform/cloudflare

 # Paste the token between the quotes; nothing in argv, nothing in history.
 printf 'cloudflare_api_token: %s\n' "<PASTED_TOKEN>" \
   | sops --encrypt \
       --filename-override terraform/cloudflare/secrets.enc.yaml \
       --input-type yaml --output-type yaml /dev/stdin \
   > terraform/cloudflare/secrets.enc.yaml

 head -3 terraform/cloudflare/secrets.enc.yaml   # expect a `sops:` block
```

If `.sops.yaml` lacks a creation rule for `terraform/cloudflare/*.enc.yaml`,
add one before encrypting (mirror the runbook 02 entry). The
`--filename-override` flag is what makes the rule match against
`secrets.enc.yaml` rather than `/dev/stdin`.

### Decision gate before Step 2

- [ ] `tokens/verify` returns `success: true`.
- [ ] `terraform/cloudflare/secrets.enc.yaml` exists, contains a `sops:`
      metadata block, and the plaintext token is **nowhere on disk**
      (`history | grep <first-8-chars-of-token>` returns nothing).
- [ ] Calendar reminder set for token rotation in 90 days.

If any box is unchecked, stop. Do not advance.

---

## Step 2 — Create the Tunnel from the `cloudflared` CLI

The new (2026) Cloudflare One UI hides the credentials-file download
behind a CLI-only flow. To create a **locally-managed** tunnel you must
use `cloudflared tunnel create` from a workstation that has the CLI
installed and an Origin Certificate. Doing this from the Mac Air keeps
the auth surface (cert.pem) confined to the operator workstation.

### 2.0 — Bootstrap a Pending Cloudflare zone (chicken-and-egg)

`cloudflared tunnel login` requires the account to have **at least one
zone** in order to issue an Origin Certificate. A brand-new account has
zero zones. Resolve this by pulling forward the first half of
[runbook 05](./05-dns-godaddy-to-cloudflare.md) for the Phase 2 pilot
zone (`cucox.me`) — adding it to Cloudflare in **Pending Nameserver
Update** state without changing nameservers at GoDaddy.

A Pending zone is harmless: Cloudflare knows it exists, but no resolver
in the world is asking Cloudflare for it. Live DNS keeps coming out of
GoDaddy unchanged.

#### 2.0.1 — Capture the GoDaddy baseline (runbook 05 § Step 1, early)

Log into GoDaddy → Domain Portfolio → `cucox.me` → DNS. Either:

- **Take a full screenshot** of the records table, **or**
- **Click Export** if GoDaddy offers a `.zone` / BIND export.

Save the export outside the repo as your rollback baseline:

```sh
mkdir -p ~/Documents/cucox-lab-archive/zone-baselines
mv ~/Downloads/cucox.me.txt ~/Documents/cucox-lab-archive/zone-baselines/cucox.me-godaddy-$(date +%Y-%m-%d).zone
```

This is non-negotiable. It is the rollback reference for everything that
follows. Per-zone analysis of what's in the export goes in
[`docs/runbooks/05a-zone-cucox-me-pre-migration.md`](./05a-zone-cucox-me-pre-migration.md)
(template for any future zone — copy and adapt for `exycle.com` and
`cucoxcorp.com` when their turn comes).

#### 2.0.2 — Add `cucox.me` to Cloudflare in Pending state

Cloudflare dashboard → top-right account picker → **Add a Site**.

1. Enter `cucox.me` → **Continue**.
2. Plan: **Free** → **Continue**.
3. Cloudflare runs an automatic record scan and pre-populates a draft.
   **Verify the draft against the GoDaddy export from Step 2.0.1**:
   - Every TXT record present, including any SaaS verification tokens
     (e.g. `asuid` for Azure App Service, `_gaiibn...`-style tokens for
     Static Web Apps). If any are missing from the draft, **add them
     manually now** — the value must be byte-identical to the GoDaddy
     export.
   - Apex A and `www` CNAME present, both **grey-clouded (DNS only)**.
     If Cloudflare orange-clouded them by default, flip to grey before
     continuing. We do not want Cloudflare proxying current
     Azure-pointing records — those get replaced by Tunnel CNAMEs in
     runbook 05 § Step 3.
   - No records present in the Cloudflare draft that are absent from
     the GoDaddy export. Delete any inferred extras (Cloudflare
     occasionally adds `mail.<domain>` heuristically).
4. Click **Continue** through the wizard until Cloudflare assigns you
   the two nameservers (e.g. `ana.ns.cloudflare.com`,
   `chuck.ns.cloudflare.com`). Save these in your scratch notes — you
   will need them in runbook 05 § Step 5.
5. **Stop at the "Confirm nameservers" / "Done, check nameservers" step.
   Do not click it. Do not change nameservers at GoDaddy.** Close the
   wizard.
6. Verify the zone is in the right state:

   ```sh
   # Should still return GoDaddy nameservers — cutover has not happened.
   dig +short NS cucox.me
   # Expect: ns57.domaincontrol.com. / ns58.domaincontrol.com.
   ```

   In the Cloudflare dashboard sidebar → **Websites** → `cucox.me`
   should show a **Pending Nameserver Update** badge.

#### Decision gate before Step 2.1

- [ ] GoDaddy DNS for `cucox.me` is unchanged (`dig +short NS cucox.me`
      returns GoDaddy nameservers).
- [ ] Cloudflare dashboard shows `cucox.me` in **Pending Nameserver
      Update** state.
- [ ] Cloudflare's draft DNS records match the GoDaddy export
      record-for-record. Every SaaS verification TXT is preserved
      verbatim.
- [ ] Apex A and `www` CNAME are **grey-clouded**, not orange.
- [ ] The two Cloudflare-assigned nameservers are saved in scratch
      notes for runbook 05 § Step 5.

### 2.1 — `cloudflared tunnel login` (account-level cert.pem)

From the Mac Air:

```sh
cloudflared tunnel login
```

What this does: opens the default browser to a Cloudflare consent page,
asks you to pick an account and a zone (`cucox.me` will appear now that
Step 2.0 is done — pick it; the Origin Certificate that gets issued is
account-scoped despite the per-zone selector text), and writes
`~/.cloudflared/cert.pem` on success.

```sh
chmod 600 ~/.cloudflared/cert.pem
ls -l ~/.cloudflared/cert.pem
# Expect: -rw------- ... cert.pem
```

> **Treat `cert.pem` like the API token from Step 1.** It can manage any
> tunnel in the account. It stays on the Mac Air at `~/.cloudflared/`.
> Never commit it. To revoke (e.g. lost laptop): delete the local file
> AND revoke from the dashboard at **Networks → Tunnels → Settings →
> Origin certificates**.

### 2.2 — Create the tunnel

```sh
cloudflared tunnel create cucox-lab-prod
```

Expected output:

```
Tunnel credentials written to /Users/cucox91/.cloudflared/<UUID>.json. cloudflared chose this file based on where your origin certificate was found. Keep this file secret. To revoke these credentials, delete the tunnel.

Created tunnel cucox-lab-prod with id <UUID>
```

That `<UUID>` is the Tunnel UUID. Capture it for Steps 5 and 8:

```sh
mkdir -p ~/.scratch
cloudflared tunnel list | awk '/cucox-lab-prod/ {print $1}' > ~/.scratch/tunnel-uuid
cat ~/.scratch/tunnel-uuid    # confirm one UUID, no extra whitespace

ls -l ~/.cloudflared/$(cat ~/.scratch/tunnel-uuid).json
# Expect ~250 bytes, mode 0600. If wider, fix:
chmod 600 ~/.cloudflared/$(cat ~/.scratch/tunnel-uuid).json
```

### 2.3 — Verify in the dashboard

Cloudflare dashboard → left sidebar → **Networks → Tunnels**.

- `cucox-lab-prod` appears in the list.
- Status: **Inactive** (correct — daemon hasn't started on `lab-edge01`
  yet; that's Step 6).
- The UUID shown matches `cat ~/.scratch/tunnel-uuid`.

If the tunnel doesn't appear, the CLI didn't reach Cloudflare. Most
common cause: stale or wrong-account `cert.pem`. `rm
~/.cloudflared/cert.pem` and re-run Step 2.1.

### 2.4 — SOPS-seal the credentials JSON

**First, confirm `.sops.yaml` has a creation rule for `*.enc.json`.**
Without one, sops fails with `error loading config: no matching
creation rules found`, **and the shell's `>` redirect leaves a
zero-byte garbage file at the destination path.** Add the rule first:

```sh
grep -E '\\.enc\\.json' "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/.sops.yaml"
# Expect a line like:  - path_regex: \.enc\.json$
# If empty, add the *.enc.json rule to .sops.yaml mirroring the *.enc.yaml one.
```

The rule was added to `.sops.yaml` during the 2026-05-01 phase-2
bootstrap session. If you're re-running this runbook from a
post-2026-05-01 commit, `grep` should match.

Then stream the CLI-generated credentials through `sops` directly into
the repo:

```sh
cd "/Users/cucox91/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
mkdir -p ansible/group_vars/lab_edge

sops --encrypt --filename-override ansible/group_vars/lab_edge/tunnel-creds.enc.json --input-type json --output-type json ~/.cloudflared/$(cat ~/.scratch/tunnel-uuid).json > ansible/group_vars/lab_edge/tunnel-creds.enc.json

head -3 ansible/group_vars/lab_edge/tunnel-creds.enc.json   # expect sops metadata, NOT empty
wc -c ansible/group_vars/lab_edge/tunnel-creds.enc.json     # expect ~1KB, NOT 0
```

If `wc -c` shows `0`, sops failed silently (the `>` redirect created
the empty file before sops even ran). Re-check the `.sops.yaml` rule
and re-run.

### 2.5 — Wipe the plaintext credentials from the Mac Air

The repo's sealed copy is the source of truth from this point on. Any
future need (re-deploy, rotate, ad-hoc CLI work) is served by
decrypting the sealed copy on the fly.

`cloudflared tunnel create` writes the credentials JSON as mode
`r--------` (read-only). `rm -P` does a 3-pass overwrite *before*
unlinking, which requires write permission on the file itself —
without write perm, the overwrite fails with `Permission denied` even
with `-f` (the `-f` flag skips the confirmation prompt but does not
grant write access). So `chmod 600` first, then `rm -P`:

```sh
chmod 600 ~/.cloudflared/$(cat ~/.scratch/tunnel-uuid).json && rm -P ~/.cloudflared/$(cat ~/.scratch/tunnel-uuid).json && ls ~/.cloudflared/
# Expect: only cert.pem in the listing
```

> **About secure-delete on SSDs.** `rm -P`'s 3-pass overwrite is largely
> theatrical on a modern SSD because of wear-leveling and TRIM —
> the overwritten data may sit on different physical pages than the
> originals. We use it as a defense-in-depth gesture, but the real
> protection is the short window the plaintext spent on disk in the
> first place (seconds, not days).

> **Why wipe rather than keep at `0600`?** Two-place secrets drift —
> if you ever rotate one copy and forget the other, recovery gets
> ambiguous. The sealed file in the repo is the single auditable
> source. The Mac Air's `cert.pem` (account-level) is enough to
> redeploy on any host that needs the credentials JSON.

### Decision gate before Step 3

- [ ] `cloudflared tunnel list` from the Mac Air shows `cucox-lab-prod`
      with the matching UUID.
- [ ] The same tunnel appears in **Networks → Tunnels** in the
      Cloudflare dashboard, status **Inactive**.
- [ ] `~/.scratch/tunnel-uuid` contains a single UUID line.
- [ ] `ansible/group_vars/lab_edge/tunnel-creds.enc.json` is a sealed
      sops file in the repo.
- [ ] No plaintext copy of the credentials JSON exists anywhere on the
      Mac Air (`find ~ -name '*.json' -path '*cloudflared*' 2>/dev/null`
      returns nothing).
- [ ] `~/.cloudflared/cert.pem` exists, mode `0600`, **not** in the
      repo.

---

## Step 3 — Firewall preflight on the UCG-Max

This is the step that previously cost ~5 hours during edge01 bringup. Do
it slowly, and verify each cell independently. Three cells must allow
the right things, in the right order, with the right return-traffic
rules. See `MEMORY.md → unifi_zone_firewall_gotchas.md` and ARCH § 3.3.4.

### 3.1 dmz → External (Internet egress)

Per ARCH § 3.3.3, dmz needs:

| Direction | Protocol/Port | Purpose |
|---|---|---|
| dmz → External | TCP 80 | apt mirrors |
| dmz → External | TCP 443 | container/binary downloads, package mirrors |
| dmz → External | TCP 7844 | cloudflared QUIC fallback (TCP) |
| dmz → External | UDP 7844 | cloudflared QUIC primary |
| dmz → External | UDP 123 | NTP |

In the UCG-Max UI: **Settings → Security → Zone Matrix → Lab-DMZ →
External cell → Manage Policies**. Verify allows exist for all five
ports above. Apply the rule-ordering invariant: any catch-all
`Block All` is the **lowest-priority (highest-ID) custom rule** in the
cell, with the specific allows above it. The Zone Matrix's effective-
policy display can read `Block All (5)` even when narrower allows
exist underneath if the Block-All rule has a lower ID; do not trust
the matrix display, open the cell's rule list and read the IDs.

After any change, **wait for "Provision Successful"** (30–60 s) before
testing.

Verify from `lab-edge01`, **before** installing cloudflared:

```sh
ssh ubuntu@10.10.30.21
# TCP 443 to a Cloudflare endpoint:
nc -zv 1.1.1.1 443
# TCP 7844:
nc -zv region1.v2.argotunnel.com 7844
# UDP 7844 (use cloudflared's own connectivity probe in dry-run mode):
sudo apt-get update -y && sudo apt-get install -y curl   # if not present
curl -fsSL --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | head -5
# UDP 123 (NTP — should already work via systemd-timesyncd):
timedatectl | grep -E 'NTP service|System clock synchronized'
```

Expected: `nc` reports `succeeded`, `curl` returns the trace
key/value lines, `timedatectl` says `System clock synchronized: yes`
and `NTP service: active`.

If any test fails, do **not** proceed. The Tunnel will silently fail to
register and you will spend an hour blaming the daemon. Common
failure modes:

- TCP 443 ok, UDP 7844 fails → cloudflared falls back to TCP 7844 (works,
  but degraded performance). Fix the UDP allow before continuing.
- All TCP/UDP fail → the `Lab-DMZ → External` cell has a catch-all
  `Block All` with a lower rule ID than the allows. Reorder.

### 3.2 dmz → cluster:443 (Tunnel upstream path)

Per ARCH § 3.3.1: `dmz → cluster: tcp/443 to ingress`. From `lab-edge01`:

```sh
ssh ubuntu@10.10.30.21 'curl -k -sI --max-time 5 https://10.10.20.50/'
# Expect: HTTP/2 404 (default backend) or HTTP/1.1 404. The status code
# is irrelevant; what matters is that a TLS handshake completes and
# nginx responds.
```

If the connection hangs (no response after 5s), the `Lab-DMZ → Lab-
Cluster` cell is dropping the SYN. Check both directions:

- Forward: `Lab-DMZ → Lab-Cluster` allow for tcp/443 to `10.10.20.50/32`.
- Return: `Lab-Cluster → Lab-DMZ` `Match State = Established, Related`
  rule (per ARCH § 3.3.5). Without this, the SYN-ACK from the cluster
  back to dmz is dropped — symptom is exactly "connection hangs, no
  ICMP error".

If the connection is refused immediately (TCP RST), nginx isn't
listening on `10.10.20.50:443`. Re-verify runbook 02 § 6.2.

### 3.3 dmz → Gateway (Local-In, for DNS + NTP)

Per ARCH § 3.3.2, dmz needs `tcp+udp/53`, `udp/123`, `udp/5353` to
`10.10.30.1`. This is a separate UniFi cell (`Lab-DMZ → Gateway`) from
the Inter-VLAN cell. Verify:

```sh
ssh ubuntu@10.10.30.21 'dig +short +time=2 +tries=1 @10.10.30.1 cloudflare.com'
# Expect: a list of A records.
```

If this fails, dmz cannot resolve `cloudflare.com` to register the
Tunnel — and cloudflared's logs will show DNS errors that look like
network failures. Open `Lab-DMZ → Gateway` in the Zone Matrix, allow
the four ports above, save, wait for provision, retest.

### Decision gate before Step 4

- [ ] All five `dmz → External` probes succeed.
- [ ] `curl https://10.10.20.50/` from `lab-edge01` completes a TLS
      handshake and gets an HTTP response (any status code).
- [ ] `dig @10.10.30.1 cloudflare.com` from `lab-edge01` returns A
      records.
- [ ] No catch-all `Block All` rule in any of the three cells has a
      lower ID than its companion allow rules. Visually re-checked in
      the UniFi UI rule-list view (not just the Zone Matrix display).

If anything fails or any allow rule had to be added/reordered to make
it pass, repeat the *full* preflight from § 3.1. Firewall changes
interact in non-obvious ways; one fix can mask another regression.

---

## Step 4 — Install `cloudflared` on `lab-edge01`

By-hand install for the first iteration (matches runbook 02's pattern of
ssh+bash before Ansible-role-ization). The Ansible role at
`ansible/roles/cloudflared/` is a Phase 4 follow-up.

### 4.1 Install the binary + systemd unit

Cloudflare does **not** publish a one-line installer at
`pkg.cloudflare.com/install.sh` (it 404s). The correct method is to add
their GPG key and apt repo manually, then `apt-get install`. Single
physical line per the paste-fragility rule:

```sh
ssh ubuntu@10.10.30.21 'sudo mkdir -p /etc/cloudflared /usr/share/keyrings && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main" | sudo tee /etc/apt/sources.list.d/cloudflared.list && sudo apt-get update && sudo apt-get install -y cloudflared && cloudflared --version'
```

The `noble` literal is the Ubuntu 24.04 codename per ARCH § 4.4. Swap
to the actual codename if `lab-edge01` is ever rebuilt on a newer
release. Confirm via `lsb_release -cs` on the host.

The `signed-by=` clause restricts package signature verification to
Cloudflare's GPG key only — apt doesn't accept Cloudflare-signed
packages from anywhere except this repo.

Expected: `cloudflared version 2026.x.x (built ...)` (or whatever the
current stable release is — verify against
[Cloudflare's release notes](https://github.com/cloudflare/cloudflared/releases)
that you're not picking up a known-buggy build).

The Cloudflare apt repo is now in `/etc/apt/sources.list.d/cloudflared.list`;
subsequent `apt-get upgrade` runs keep the binary current.

### 4.2 Create a dedicated system user

cloudflared ships a default systemd unit that runs as root. We replace
it with a unit that runs as a dedicated unprivileged user — the Tunnel
needs no privileges beyond reading its own credentials and binding
outbound sockets. Per the same security-conservative posture: do not
run network-reachable services as root when you do not have to.

```sh
ssh ubuntu@10.10.30.21 'sudo useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared 2>/dev/null || true; sudo chown -R cloudflared:cloudflared /etc/cloudflared'
```

### 4.3 Deliver the credentials file

The credentials JSON is decrypted on the Mac Air, streamed over ssh,
and written directly to `/etc/cloudflared/creds.json` on the edge VM.
Plaintext never touches the Mac Air's disk.

```sh
sops --decrypt ansible/group_vars/lab_edge/tunnel-creds.enc.json | ssh ubuntu@10.10.30.21 'sudo tee /etc/cloudflared/creds.json >/dev/null && sudo chown cloudflared:cloudflared /etc/cloudflared/creds.json && sudo chmod 0600 /etc/cloudflared/creds.json && sudo ls -l /etc/cloudflared/creds.json'
```

Expected `ls` line:

```
-rw------- 1 cloudflared cloudflared 247 <date> /etc/cloudflared/creds.json
```

If the size is anywhere near 0 or the owner is `root`, fix it before
moving on.

### Decision gate before Step 5

- [ ] `cloudflared --version` works on `lab-edge01`.
- [ ] `cloudflared` system user exists (`getent passwd cloudflared`).
- [ ] `/etc/cloudflared/creds.json` is `0600 cloudflared:cloudflared`.
- [ ] No plaintext copy of the credentials JSON exists on the Mac Air
      under `~`.

---

## Step 5 — Stage the minimal `config.yaml`

The first `config.yaml` deployed to `lab-edge01` has **no public
hostname routes**. Only the catch-all 404. This is deliberate: the
tunnel must register with Cloudflare and prove it can carry traffic
*before* any public hostname maps to it.

### 5.1 Create the template in the repo

`cloudflared/config.yaml.tmpl`:

```yaml
# Cloudflared configuration for lab-edge01 (Phase 2).
# Source of truth: ARCHITECTURE.md § 6.3.
# Materialized to /etc/cloudflared/config.yaml on lab-edge01.

tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/creds.json

# Connection tuning. Defaults are sane; these are explicit so the
# config self-documents.
protocol: quic                # uses UDP 7844 (preferred); falls back to TCP 7844
loglevel: info
metrics: 127.0.0.1:2000        # Prometheus scrape target (runbook 04)
no-autoupdate: true            # apt manages the binary; daemon never self-updates

# Hostname routes are added per-domain by runbook 05. Until then the
# tunnel is registered but routes nothing public. The catch-all MUST
# remain the last entry.
ingress:
  # --- runbook 05 fills this section, one block per migrated zone ---
  # - hostname: cucox.me
  #   service: https://10.10.20.50:443
  #   originRequest:
  #     noTLSVerify: true
  #     httpHostHeader: cucox.me
  # - hostname: www.cucox.me
  #   service: https://10.10.20.50:443
  #   originRequest:
  #     noTLSVerify: true
  #     httpHostHeader: www.cucox.me
  # ----------------------------------------------------------------
  - service: http_status:404
```

> **Why `httpHostHeader` is set per route.** The upstream is the
> ingress VIP `10.10.20.50:443`, not a hostname. Without an explicit
> `httpHostHeader`, cloudflared sends `Host: 10.10.20.50` to nginx,
> which fails to match any `Ingress` rule (those match on the public
> hostname). Setting `httpHostHeader: <hostname>` makes nginx see the
> request as if it came directly from the public client, and the
> `Ingress` rules match. This is a Phase-2-specific concern — when
> Phase 5 moves cloudflared in-cluster and the upstream becomes the
> Service DNS name, the routing still works without `httpHostHeader`
> because the Service abstraction handles `Host` differently.
>
> **Why `noTLSVerify: true`.** ingress-nginx terminates TLS with a
> self-signed cert (cert-manager + Let's Encrypt is a Phase 3 follow-up,
> ARCH § 5.4 footnote candidate). cloudflared must not validate the
> upstream cert until that lands. Documented in ADR-0014 (forthcoming)
> as a time-boxed exception.

### 5.2 Materialize the template into `/etc/cloudflared/config.yaml`

Substitute the Tunnel UUID locally, stream the result to the host, and
let `tee` write it under the cloudflared user.

```sh
sed "s/<TUNNEL_UUID>/$(cat ~/.scratch/tunnel-uuid)/" cloudflared/config.yaml.tmpl | ssh ubuntu@10.10.30.21 'sudo tee /etc/cloudflared/config.yaml >/dev/null && sudo chown cloudflared:cloudflared /etc/cloudflared/config.yaml && sudo chmod 0644 /etc/cloudflared/config.yaml'
```

Validate the config syntactically *before* starting the daemon:

```sh
ssh ubuntu@10.10.30.21 'sudo -u cloudflared cloudflared --config /etc/cloudflared/config.yaml ingress validate'
```

Expected output depends on the cloudflared version:

- **Older builds** (pre-2026): `Validating rules from /etc/cloudflared/config.yaml` then `OK`, exit 0.
- **2026+ builds** (verified during runbook 04 execution on 2026-05-01):
  when the ingress section is mostly the catch-all 404 (no real
  rules to validate), cloudflared short-circuits to a hint —
  `Use \`cloudflared tunnel run\` to start tunnel <UUID>` — and exits
  with a non-zero code. **This non-zero exit is not a failure** in
  this scenario; it's a CLI semantic change. The actual proof that
  the config is valid is whether the daemon starts cleanly in Step
  6.2 and whether the tunnel registers 4 connections.

In either case, if the output mentions an actual parse error
(unknown field, malformed YAML, etc.), fix the template and re-deploy
before doing anything else. Starting cloudflared with a genuinely
broken config gets you confusing systemd retry loops.

### Decision gate before Step 6

- [ ] `/etc/cloudflared/config.yaml` exists on `lab-edge01` with the
      Tunnel UUID substituted in.
- [ ] `cloudflared --config ... ingress validate` either returns `OK` (older builds) or the `Use \`cloudflared tunnel run\` to start tunnel <UUID>` hint (2026+ builds with the catch-all-only ingress). Either output indicates the config parsed; an actual parse error has different wording (unknown field, malformed YAML, etc.).
- [ ] No active hostname routes are present (only the `http_status:404`
      catch-all). This is correct for runbook 03; runbook 05 will add
      hostnames.

---

## Step 6 — Start `cloudflared` and validate Tunnel registration

The Cloudflare apt package installs the binary but **does not ship a
systemd unit** — `systemctl is-enabled cloudflared` returns `not-found`
right after install (verified empirically during the 2026-05-01
bootstrap). Two options:

- Run `cloudflared service install` to auto-generate one (runs as root
  by default — would need a drop-in override anyway).
- Write the unit from scratch with our exact security posture.

We use the second option — explicit is reviewable, and the unit only
takes ~25 lines. Stored in the repo at
[`ansible/roles/cloudflared/files/cloudflared.service`](../../ansible/roles/cloudflared/files/cloudflared.service)
so the future Ansible role (Phase 4) can reuse it verbatim.

### 6.1 — Write the systemd unit on lab-edge01

Stream the unit file to `/etc/systemd/system/cloudflared.service`,
then `daemon-reload`:

```sh
ssh ubuntu@10.10.30.21 'sudo tee /etc/systemd/system/cloudflared.service >/dev/null <<UNIT
[Unit]
Description=Cloudflare Tunnel daemon (lab-edge01 -> cucox-lab-prod)
Documentation=docs/runbooks/03-phase2-cloudflared-tunnel.md
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=cloudflared
Group=cloudflared
ExecStart=/usr/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yaml tunnel run
Restart=on-failure
RestartSec=5s
TimeoutStartSec=0

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/cloudflared

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload && sudo systemctl cat cloudflared | head -10'
```

The hardening directives are minimum-viable defense in depth:

| Directive | Effect |
|---|---|
| `NoNewPrivileges=true` | Process can't gain privileges via setuid/setcap |
| `ProtectSystem=strict` | Filesystem read-only except `/dev`, `/proc`, `/sys` |
| `ProtectHome=true` | `/home`, `/root`, `/run/user` inaccessible |
| `PrivateTmp=true` | Daemon gets its own private `/tmp` |
| `ReadOnlyPaths=/etc/cloudflared` | Belt-and-suspenders on the config dir |

The `Type=notify` requires cloudflared to send sd_notify READY — recent
versions support this; older ones may need `Type=simple`.

### 6.2 — Start the service and watch it register

```sh
ssh ubuntu@10.10.30.21 'sudo systemctl enable --now cloudflared && sleep 3 && sudo systemctl status cloudflared --no-pager'
```

Then tail the journal for ~30 seconds to watch registration:

```sh
ssh ubuntu@10.10.30.21 'sudo journalctl -fu cloudflared'    # Ctrl-C after observation
```

Expected log lines (within 10–15 seconds of start):

```
INF Starting tunnel tunnelID=<UUID>
INF Version 2026.x.x ...
INF Initial protocol quic
INF Connection <conn-uuid> registered connIndex=0 ip=<edge-ip> location=<colo>
INF Connection <conn-uuid> registered connIndex=1 ip=<edge-ip> location=<colo>
INF Connection <conn-uuid> registered connIndex=2 ip=<edge-ip> location=<colo>
INF Connection <conn-uuid> registered connIndex=3 ip=<edge-ip> location=<colo>
```

Four registered connections (to two different Cloudflare colos for HA)
is the healthy steady-state. If you see fewer than 4 after 60 s, or
repeated `ERR Failed to ... ` lines, stop and re-check Step 3. Most
"connection registered then dropped" loops trace back to `dmz → External
UDP 7844` being silently dropped on retry.

### 6.3 Confirm in the Cloudflare dashboard

**Zero Trust → Networks → Tunnels → cucox-lab-prod**.

- Status: **HEALTHY** (green).
- Connector count: **1** (the lab-edge01 daemon).
- Connections: **4** (or whatever your colo geometry produced).
- "Last seen": within the last 30 s.

### Decision gate before Step 7

- [ ] Tunnel is **HEALTHY** in the Cloudflare dashboard.
- [ ] `journalctl -u cloudflared` is clean (no `ERR` lines) over a
      **continuous 5-minute observation window**. Do not skip the
      window. Transient registration errors that recur are easier to
      catch over 5 minutes than over 30 seconds.
- [ ] `systemctl is-enabled cloudflared` returns `enabled`.
- [ ] `systemctl is-active cloudflared` returns `active`.

---

## Step 7 — Validate the upstream path end-to-end

The Tunnel is up; the upstream pipe is configured; nothing public
points at it yet. Validate the upstream half **from the perspective of
the cloudflared daemon** — same source IP, same TLS posture, same
`Host` header it would send under load.

### 7.1 Synthetic local test from `lab-edge01`

Spin up a temporary smoke deployment + ingress in the cluster (the
runbook 02 `smoke` namespace was torn down at end of § 6.3, so this
recreates it):

```sh
kubectl create namespace smoke
kubectl -n smoke create deploy hello --image=nginxdemos/hello --port=80
kubectl -n smoke expose deploy hello --port=80
kubectl -n smoke create ingress hello --class=nginx --rule="hello.lab.cucox.local/*=hello:80"
```

From `lab-edge01`, simulate the request cloudflared would make on
behalf of a public client routed to `hello.lab.cucox.local`:

```sh
ssh ubuntu@10.10.30.21 'curl -ksI --max-time 5 -H "Host: hello.lab.cucox.local" https://10.10.20.50/'
# Expect: HTTP/2 200, with `Server: nginx/...` (the hello demo).
```

If this returns 200, the upstream path is correct: cloudflared can
reach `10.10.20.50:443`, complete TLS, and have nginx route to the
hello-demo Service via the Host header. This is exactly what cloudflared
will do in production with `httpHostHeader: <real-hostname>`.

### 7.2 Tear down the smoke namespace

Conservatism: do not leave a test workload in place after validation.

```sh
kubectl delete namespace smoke
```

### 7.3 Tunnel-side metrics check

cloudflared exposes Prometheus metrics on `127.0.0.1:2000` per the
config (Step 5.1). From `lab-edge01`:

```sh
ssh ubuntu@10.10.30.21 'curl -s http://127.0.0.1:2000/metrics | grep -E "^(cloudflared_tunnel_(total_requests|active_streams|server_locations))" | head'
```

Expected: gauge/counter lines exist (values may be near-zero — no public
traffic yet). The presence of `cloudflared_tunnel_server_locations`
labeled with the colo name confirms the daemon believes it has a live
session with Cloudflare edge.

### Decision gate before Step 8

- [ ] Synthetic upstream curl from `lab-edge01` returned `HTTP/2 200`
      from the hello-demo via the ingress VIP.
- [ ] `smoke` namespace is deleted.
- [ ] `127.0.0.1:2000/metrics` returns Prometheus-format metrics
      including `cloudflared_tunnel_server_locations`.

---

## Step 8 — Terraform-track the Tunnel resource

The Tunnel currently exists as a hand-clicked Cloudflare resource. Bring
it under Terraform so future changes (rename, account move, deletion,
new connector) are reviewable.

### 8.1 Provider + variables

`terraform/cloudflare/providers.tf`:

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.40"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

`terraform/cloudflare/variables.tf`:

```hcl
variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Scoped token; see runbook 03 § 1."
}

variable "cloudflare_account_id" {
  type        = string
  description = "Account ID — find in the Cloudflare dashboard sidebar."
}

variable "tunnel_uuid" {
  type        = string
  description = "UUID of the cucox-lab-prod tunnel (created via CLI, imported in this module)."
}

variable "tunnel_secret" {
  type        = string
  sensitive   = true
  description = "Base64-encoded tunnel secret. Cloudflare provider v4.40+ requires this on the tunnel resource even when the tunnel was created out-of-band. Extracted from the SOPS-sealed creds JSON."
}
```

`terraform/cloudflare/secrets.auto.tfvars` is **not** committed; the
token AND the tunnel secret come from the SOPS-encrypted files via
on-the-fly decryption (avoid plaintext on disk):

```sh
cd terraform/cloudflare
export TF_VAR_cloudflare_api_token="$(sops --decrypt secrets.enc.yaml | yq -r .cloudflare_api_token)"
export TF_VAR_cloudflare_account_id="<your account id>"
export TF_VAR_tunnel_uuid="$(cat ~/.scratch/tunnel-uuid)"
export TF_VAR_tunnel_secret="$(sops --decrypt ../../ansible/group_vars/lab_edge/tunnel-creds.enc.json | jq -r .TunnelSecret)"
terraform init
```

### 8.2 Define the resource and import

`terraform/cloudflare/tunnel.tf`:

```hcl
resource "cloudflare_zero_trust_tunnel_cloudflared" "cucox_lab_prod" {
  account_id = var.cloudflare_account_id
  name       = "cucox-lab-prod"
  secret     = var.tunnel_secret
  config_src = "local"   # documents intent; not actionable drift (see lifecycle below)

  # Lifecycle ignores:
  # secret      — rotating it here would invalidate creds.json on lab-edge01
  # config_src  — Cloudflare's API does not return this on read, so without
  #               this ignore Terraform sees (null) → "local" and marks it
  #               ForceNew, planning a destroy+recreate of the tunnel that
  #               would invalidate creds.json
  lifecycle {
    ignore_changes = [secret, config_src]
  }
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.id
}

output "tunnel_cname" {
  description = "CNAME target for any hostname routed through this tunnel."
  value       = "${cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod.id}.cfargotunnel.com"
}
```

Plus the declarative `import` block above the resource:

```hcl
import {
  to = cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod
  id = "${var.cloudflare_account_id}/${var.tunnel_uuid}"
}
```

This makes the import declarative — the first `terraform plan/apply`
that sees this block performs the import; subsequent plans no-op the
directive. Keeps `var.tunnel_uuid` referenced (satisfies tflint's
`terraform_unused_declarations`) and provides a reproducible re-import
path if state is ever lost.

**Lessons from the 2026-05-01 first import** (preserved here so the next
person doesn't re-derive them):

1. **`secret` is required by provider v4.40+** even when importing an
   out-of-band-created tunnel. Without it, `terraform plan` errors with
   `Missing required argument`. Source it from the SOPS-sealed creds
   JSON via `TF_VAR_tunnel_secret`.
2. **`config_src` is set-only on the Cloudflare API** — it doesn't echo
   back on read. Without `lifecycle.ignore_changes = [config_src]`, every
   `terraform plan` proposes a destroy+recreate of the tunnel, which
   would invalidate creds.json and break the live tunnel.
3. **`var.tunnel_uuid` must be referenced somewhere in HCL** or
   tflint's `terraform_unused_declarations` rule fails the pre-commit
   hook. The `import` block above does this — keeps the variable
   load-bearing without requiring a manual `terraform import` command.

Import the existing resource:

```sh
terraform import \
  cloudflare_zero_trust_tunnel_cloudflared.cucox_lab_prod \
  "${TF_VAR_cloudflare_account_id}/${TF_VAR_tunnel_uuid}"

terraform plan
# Expect: "No changes. Your infrastructure matches the configuration."
```

If `plan` shows changes, the resource definition does not yet match the
dashboard-created reality. Adjust attributes in `tunnel.tf` (most
commonly `config_src` or absent fields) until `plan` is clean. Do not
`apply` over a non-empty plan unless you know exactly what's drifting.

### Decision gate before Step 9

- [ ] `terraform plan` is clean ("No changes").
- [ ] `terraform/cloudflare/secrets.auto.tfvars` does not exist
      (plaintext token must not be on disk).
- [ ] The `tunnel_id` output matches the UUID you noted in Step 2.

---

## Step 9 — Snapshot, document, file edits

### 9.1 Per-VM snapshot

```sh
ssh root@10.10.10.10 'qm snapshot 141 phase2-cloudflared --description "post cloudflared install + tunnel registered"'
# 141 is lab-edge01's vmid; adjust if your terraform inventory chose a different ID.
```

### 9.2 Update ARCHITECTURE.md decision log

Add a row to ARCH § 12 (file edit only — Claude Code handles git):

```
| 0014 | 2026-04-30 | Phase 2 cloudflared upstream targets ingress VIP `10.10.20.50` directly rather than the in-cluster Service DNS sketched in ARCH § 6.3. Time-boxed deviation: closes when Phase 5 moves cloudflared in-cluster. ADR-0014. | Active (deviation) |
```

Stub `docs/decisions/0014-cloudflared-edge-vm-upstream-vip.md` with:

- Status: Active (deviation)
- Context: ARCH § 6.3 sketch assumes in-cluster cloudflared.
- Decision: target `https://10.10.20.50:443` from external lab-edge01.
- Consequences: must set `httpHostHeader` per route (Step 5.1).
- Closes when: Phase 5 in-cluster cloudflared lands.

### 9.3 Files to commit on a `phase2-cloudflared` branch

(Claude Code handles `git`; this runbook lists the file set so the
commit is reviewable.)

**New files:**

| Path | Purpose |
|---|---|
| `cloudflared/config.yaml.tmpl` | Templated config — UUID-substituted into `/etc/cloudflared/config.yaml` |
| `ansible/roles/cloudflared/files/cloudflared.service` | Systemd unit (deployed by Step 6.1; future Ansible role consumes verbatim) |
| `ansible/group_vars/lab_edge/tunnel-creds.enc.json` | SOPS-encrypted Tunnel credentials |
| `terraform/cloudflare/providers.tf` | Provider pin (cloudflare/cloudflare ~> 4.40) |
| `terraform/cloudflare/variables.tf` | Variable definitions (token, account_id, tunnel_uuid, tunnel_secret) |
| `terraform/cloudflare/tunnel.tf` | Imported Tunnel resource with lifecycle ignores |
| `terraform/cloudflare/secrets.enc.yaml` | SOPS-encrypted Cloudflare API token |
| `docs/runbooks/03-phase2-cloudflared-tunnel.md` | This file (with all 2026-05-01 lessons captured inline) |
| `docs/runbooks/05a-zone-cucox-me-pre-migration.md` | Per-zone analysis for `cucox.me` (consumed by runbook 05) |
| `docs/decisions/0014-cloudflared-edge-vm-upstream-vip.md` | ADR for the Phase 2 ingress-VIP-vs-Service-DNS deviation |

**Edited files:**

| Path | Change |
|---|---|
| `.sops.yaml` | New `*.enc.json` creation rule (added 2026-05-01 to support tunnel-creds.enc.json) |
| `docs/runbooks/05-dns-godaddy-to-cloudflare.md` | "Note on early-start state from runbook 03" block at top — explains the partial pre-completion of Step 1+2 for `cucox.me` during runbook 03 § 2.0 |
| `ARCHITECTURE.md` | § 12 decision log row 0014 added |

**Ignored (must NOT be committed):**

| Path | Why |
|---|---|
| `terraform/cloudflare/.terraform/` | Downloaded providers (regeneratable) |
| `terraform/cloudflare/.terraform.lock.hcl` | OK to commit; pins provider version. Verify `git status` shows it as new file. |
| `terraform/cloudflare/terraform.tfstate*` | State files — contain tunnel secret in plaintext; treat as credential |
| `terraform/cloudflare/secrets.auto.tfvars` | Should not exist; if it does, rm first |
| `~/.cloudflared/cert.pem` | Account-level Cloudflare auth; not in repo |
| `~/.scratch/tunnel-uuid` | Operator scratch; not in repo |

---

## Rollback

The right rollback depends on *what* failed and *when*.

### Tunnel registers but won't carry traffic (Step 6 → Step 7 transition)

- Symptoms: HEALTHY in dashboard, `cloudflared_tunnel_server_locations`
  populated, but synthetic upstream curl from `lab-edge01` hangs or
  502s.
- Action: do **not** delete the Tunnel. Re-run Step 3.2 (dmz → cluster
  firewall preflight) and Step 5.2 (`ingress validate`). Most failures
  here are "I tightened the firewall after Step 3 and forgot the
  return-traffic rule on the new cell".

### `cloudflared` keeps crashing or won't start (Step 6)

- `journalctl -u cloudflared -e` for the actual error.
- Common causes:
  - `creds.json` not readable by the `cloudflared` user
    (mode/ownership) → re-run Step 4.3.
  - `config.yaml` references a Tunnel UUID that doesn't match the creds
    → re-run Step 5.2 with the correct UUID.
  - dmz → External UDP 7844 dropped → cloudflared retries on TCP 7844
    indefinitely; fix Step 3.1 and `systemctl restart cloudflared`.
- VM-level revert: `ssh root@10.10.10.10 'qm rollback 141 phase1-base'`.
  This drops all of Step 4–6 and you redo from a clean Ubuntu image.

### Tunnel never registers (Step 6)

- Tunnel still appears as **Inactive** in the dashboard after 60 s.
- Action: `cloudflared tunnel info <UUID>` from the Mac Air with `cloudflared`
  CLI and a token, to confirm the Tunnel exists at Cloudflare's side.
  If it does, the daemon on `lab-edge01` is the broken half — see
  previous bullet.
- If the Tunnel was deleted in the dashboard accidentally, you cannot
  re-create it with the same UUID. Create a new Tunnel (Step 2),
  re-seal new credentials, re-deploy. The Terraform state from Step 8
  must be `terraform state rm`-ed and re-imported against the new UUID.

### Cloudflare API token compromised

- Revoke at **My Profile → API Tokens → cucox-lab-prod-token →
  Revoke**.
- Re-do Step 1 with a new token. Re-encrypt `secrets.enc.yaml`. Re-run
  `terraform plan` to confirm Terraform still talks to Cloudflare.
- **Tunnel credentials JSON is not the API token.** Compromising the
  API token does **not** require recreating the Tunnel. Compromising
  `creds.json` does — see the next bullet.

### Tunnel credentials JSON compromised

- **Zero Trust → Networks → Tunnels → cucox-lab-prod → Delete**. The
  credentials JSON is now useless to the attacker (no Tunnel to use it
  against).
- Recreate the Tunnel (Step 2), re-seal new credentials, re-deploy.
- Update `terraform import` per the previous bullet.
- Investigate how the compromise happened *before* re-creating: if a
  laptop is compromised, deleting the Tunnel doesn't help.

---

## Done when

- [ ] Tunnel `cucox-lab-prod` exists in Cloudflare, status **HEALTHY**,
      4 active connections, "Last seen" updating in real time.
- [ ] `cloudflared` is `enabled` and `active` on `lab-edge01`, running
      as the `cloudflared` system user (not root).
- [ ] `journalctl -u cloudflared` has zero `ERR` lines over a
      continuous 5-minute window.
- [ ] Synthetic upstream curl (Step 7.1) returned 200 from a temporary
      hello-demo via `https://10.10.20.50/` with the right `Host`
      header.
- [ ] `smoke` namespace is deleted.
- [ ] `cloudflared/config.yaml` on `lab-edge01` has only the
      `http_status:404` route (no public hostnames yet — runbook 05
      adds them).
- [ ] `terraform plan` in `terraform/cloudflare/` is clean.
- [ ] `lab-edge01` has a `phase2-cloudflared` snapshot.
- [ ] ADR-0014 stub exists; ARCH § 12 has the corresponding row.
- [ ] No plaintext copy of the Tunnel credentials JSON or the
      Cloudflare API token exists anywhere outside the SOPS-encrypted
      files in the repo.
- [ ] No public hostname resolves to the Tunnel UUID. Verify:

      ```sh
      dig +short cucox.me                  # still resolves to GoDaddy/old host
      dig +short www.cucox.me              # same
      dig +short <UUID>.cfargotunnel.com   # returns Cloudflare IPs (this is fine — every Tunnel has this)
      ```

      The first two MUST still answer with the old infrastructure until
      runbook 05 cuts over. If either one already points at the Tunnel,
      stop — runbook 05's gating logic depends on the cutover being a
      deliberate, single act.

---

## Quick reference

### Where things live

| Thing | Location |
|---|---|
| Tunnel name | `cucox-lab-prod` |
| Tunnel UUID | `~/.scratch/tunnel-uuid` (Mac Air, gitignored) + Terraform output |
| Tunnel credentials (sealed) | `ansible/group_vars/lab_edge/tunnel-creds.enc.json` |
| Tunnel credentials (deployed) | `/etc/cloudflared/creds.json` on `lab-edge01` (`0600 cloudflared:cloudflared`) |
| cloudflared config (template) | `cloudflared/config.yaml.tmpl` |
| cloudflared config (deployed) | `/etc/cloudflared/config.yaml` on `lab-edge01` |
| systemd unit override | `/etc/systemd/system/cloudflared.service.d/override.conf` |
| Cloudflare API token (sealed) | `terraform/cloudflare/secrets.enc.yaml` |
| Terraform state (Tunnel) | `terraform/cloudflare/terraform.tfstate` |
| Upstream target (Phase 2) | `https://10.10.20.50:443` (ingress-nginx VIP) |
| cloudflared metrics endpoint | `127.0.0.1:2000/metrics` on `lab-edge01` |

### Diagnostic one-liners

```sh
# Daemon status + recent logs.
ssh ubuntu@10.10.30.21 'sudo systemctl status cloudflared --no-pager; sudo journalctl -u cloudflared -n 50 --no-pager'

# Connection count from the metrics endpoint.
ssh ubuntu@10.10.30.21 'curl -s http://127.0.0.1:2000/metrics | grep cloudflared_tunnel_active_streams'

# Validate the in-place config.
ssh ubuntu@10.10.30.21 'sudo -u cloudflared cloudflared --config /etc/cloudflared/config.yaml ingress validate'

# Upstream reachability (no Host header → expect 404 from default backend).
ssh ubuntu@10.10.30.21 'curl -ksI --max-time 5 https://10.10.20.50/'

# Tunnel inventory from the operator side (requires ~/.cloudflared/cert.pem
# from `cloudflared tunnel login` if you've done that on the Mac Air).
cloudflared tunnel list
```

### Rollback ladder

1. **Config-level revert.** `kubectl delete -f` of any test workload;
   restore `/etc/cloudflared/config.yaml` from the previous template
   commit; `systemctl restart cloudflared`.
2. **Daemon revert.** `apt-get install --reinstall cloudflared` (pulls
   current package); re-deliver creds + config (Step 4.3 + Step 5.2).
3. **VM revert.** `qm rollback 141 phase2-cloudflared` (this runbook's
   snapshot — undoes daemon install and config).
4. **VM revert deeper.** `qm rollback 141 phase1-base` (runbook 01 's
   pre-cloudflared baseline) — you redo this entire runbook from Step 4.
5. **Tunnel revert.** Delete the Tunnel in Cloudflare; recreate per
   Step 2; re-import Terraform per Step 8. Only do this if the Tunnel
   itself is what's broken (very rare).

---

## Hand-off

Next: [`04-phase2-observability.md`](./04-phase2-observability.md) —
`kube-prometheus-stack` install, ServiceMonitor for ingress-nginx, the
`cloudflared` `127.0.0.1:2000/metrics` endpoint scraped via a static
target, and Grafana behind ingress (still no public hostname; that's
runbook 05). Observability lands *before* the first public cutover so
runbook 05's validation steps have dashboards to read.

After runbook 04: [`05-dns-godaddy-to-cloudflare.md`](./05-dns-godaddy-to-cloudflare.md)
— migrate `cucox.me` first. Runbook 05's Step 3 fills in the first
hostname block in `cloudflared/config.yaml.tmpl`, materializes it onto
`lab-edge01`, and reloads cloudflared. The first public request lands
**only** when runbook 05's Step 5 (NS change at GoDaddy) completes —
not before.
