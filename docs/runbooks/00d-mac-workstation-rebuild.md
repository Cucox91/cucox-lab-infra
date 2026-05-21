# Runbook 00d — Mac Workstation Rebuild (Pre-Reset Prep & Post-Reset Restore)

> **Goal:** Factory-reset the management Mac without losing access to the
> cluster, the encrypted secrets in this repo, the Cloudflare zone, or any
> of the upstream control planes (UniFi, GoDaddy, GitHub). Come back up on
> the fresh Mac in under an hour, with `terraform plan` showing zero diff
> and `kubectl get nodes` showing every node Ready.
>
> **Estimated time:** 60–90 minutes for prep, 30–45 minutes for the
> post-reset rebuild. Add another 15 minutes the first time you do the
> restore-test (Step 13) because you'll probably uncover one gap.
>
> **When to run:** Any time the management Mac is being wiped, replaced,
> traded in, or its SSD is being swapped. Also a useful periodic exercise:
> doing Steps 1–13 once a quarter without actually wiping proves your
> off-Mac access paths still work.
>
> **Operator:** Raziel, on the Mac being reset, plus a second device
> (phone or other laptop) to validate restore paths before the wipe.

---

## The mental model: two irreplaceable secrets, three fallback paths

A "wipe my Mac" event has two independent failure modes, each defended
by a different layer. Skipping a layer leaves you locked out of a
specific class of things, often discovered the morning after the reset.

| Failure mode | What goes wrong without the layer | Layer that defends |
|---|---|---|
| Lose the **age private key** | Every `*.enc.yaml` / `*.enc.json` in the repo becomes unreadable. Cloudflare API token, k3s join token, tunnel credentials, Grafana admin — all gone. The repo still clones, sops just refuses to decrypt. | **Step 4** — back up `~/.config/sops/age/keys.txt`. Public half is `age1z7fje8ex3...vdutld`; the private half is gitignored and lives only on this Mac. |
| Lose local **Terraform state** | `terraform/cloudflare/terraform.tfstate*` is gitignored. After a wipe, `terraform plan` thinks Cloudflare resources don't exist and proposes to create them. Apply that and you've blown away your zone + tunnel config. | **Step 7** — bundle tfstate + lock files. (Long-term fix: move to a remote backend; until then, treat the local state as load-bearing.) |

Three fallback paths protect against the *primary* recovery path failing
(corrupt bundle, forgotten passphrase, drive failure):

1. **A second SSH key authorized on every host**, generated on a device
   that is *not* being wiped (Step 5). If the bundle is unreadable, you
   can still get into `lab-prox01` and pull `/etc/rancher/k3s/k3s.yaml`.
2. **Password manager + TOTP on a device that is *not* being wiped**
   (Step 2). Cloudflare and UniFi can be re-authenticated from their
   dashboards if the local creds are lost.
3. **kubeconfig is re-fetchable from the cluster** (Step 6) — copying
   it is cheap insurance, not a hard dependency.

---

## What this runbook does NOT cover

- **Migrating to a fundamentally different OS** (e.g., Mac → Linux
  workstation). The bundle structure works, but post-restore tool paths
  (`~/.config/sops/age/keys.txt` vs `~/Library/Application Support/...`)
  differ. Out of scope here.
- **Rotating credentials as part of the rebuild.** If you have reason
  to believe the old Mac was compromised, don't restore the bundle —
  rotate every key it would have contained (age key, SSH keys,
  Cloudflare API token, k3s join token, UniFi local admin password,
  GitHub PAT). That's a separate, much longer workflow.
- **Restoring Proxmox / cluster data from backup.** This runbook only
  protects *workstation* state. The cluster itself is backed up per
  runbook 00c (power-failure recovery) and the Proxmox baseline.
- **Apple ID account recovery.** If you lose access to your Apple ID
  itself, Apple's recovery process is the only path. Verify your Apple
  ID recovery contact/key situation independently before reset.

---

## Prerequisites

- A second device — phone or another laptop — that is **not** being
  wiped. Used for restore-test (Step 13) and for at least one of the
  fallback paths.
- Password manager unlockable on that second device. Confirm before
  starting — not while staring at the wiped Mac.
- An external drive (USB / SSD) **and** access to one cloud storage
  location (iCloud Drive, Drive, S3, etc.) for the two-copy rule.
- A passphrase you can memorize, or that lives in the password manager,
  for sealing the bundle (Step 11). Do **not** reuse an existing
  service password.
- About 60–90 minutes of focused time. Don't interleave with other
  work; the failure modes here are silent.

---

## Step 1 — Take inventory (read-only)

Before changing anything, see what's actually on this Mac that matters.
This is the success criterion for Steps 4–9: every non-empty directory
listed here must end up in the bundle.

```sh
ls -la ~/.ssh ~/.kube ~/.config/sops/age ~/.cloudflared ~/.docker 2>/dev/null
find "$HOME/Documents/Claude/Projects/Cucox Lab" -name 'terraform.tfstate*' -o -name '.terraform.lock.hcl' 2>/dev/null
cd "$HOME/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra" && git status --porcelain && git stash list
```

Expected output:

- `~/.ssh/` — `id_*` private keys, `id_*.pub`, `config`, `known_hosts`.
- `~/.kube/config` — the k3s kubeconfig (single file).
- `~/.config/sops/age/keys.txt` — the age private key. **This file
  must exist.** If it doesn't, sops decrypt has been failing silently
  and you need to address that before doing anything else.
- `~/.cloudflared/` — may not exist on the Mac if the connector only
  runs on `lab-edge01` (per runbook 03 § 2.4). That's fine.
- `~/.docker/config.json` — may not exist if you haven't logged into
  any registry from this Mac. Fine.
- `terraform.tfstate` files under `terraform/cloudflare/` and any
  other `terraform/<provider>/` directory. **These must be backed
  up** — gitignored.
- `git status --porcelain` — anything listed is uncommitted and will
  vanish on reset unless captured in Step 10.

If `~/.config/sops/age/keys.txt` is missing, stop and recover it from
wherever it actually lives before proceeding. Common alternates:
`~/.sops/`, `~/Library/Application Support/sops/age/`, or a custom
`SOPS_AGE_KEY_FILE` environment variable. Check `echo $SOPS_AGE_KEY_FILE`.

---

## Step 2 — Verify password manager + MFA on the second device

Before touching files on the Mac:

1. Open your password manager (1Password / Bitwarden / Apple Passwords)
   on the second device. Unlock it with the master password — not
   FaceID. If you don't remember the master password without biometrics,
   you'll be locked out of the new Mac.
2. Confirm TOTP seeds for every load-bearing account are either in the
   vault or in an Authenticator app that syncs:
   - **Apple ID** (without this, the new Mac is a brick)
   - **Cloudflare** (zone + tunnel control plane)
   - **GoDaddy** (mid-migration; see runbooks 05/05a/05b)
   - **GitHub** (push access to this repo)
   - **UniFi SSO** (if you use it; local admin is a fallback)
   - **AWS / Azure / any cloud the lab touches**
3. If any TOTP seed lives only in this Mac's Authenticator app,
   export it now (QR or text) and put it in the vault. This is the
   single most common factory-reset disaster.

Do not proceed until every TOTP can be generated on the second device.

---

## Step 3 — Stage a working directory

Single bundle. No scattered backups in `~/Downloads`.

```sh
mkdir -p ~/mac-reset-bundle && cd ~/mac-reset-bundle
```

Everything in Steps 4–10 lands here; everything outside `~/mac-reset-bundle`
should be treated as discardable at the end.

---

## Step 4 — Back up the SOPS age key

The single most irreplaceable file on this Mac.

```sh
cp -p ~/.config/sops/age/keys.txt ~/mac-reset-bundle/sops-age-keys.txt
chmod 600 ~/mac-reset-bundle/sops-age-keys.txt
sops -d "$HOME/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra/terraform/cloudflare/secrets.enc.yaml" | head -5
```

The third line is the **proof**. If it prints decrypted YAML
(`cloudflare_api_token: ...` or similar), the key works and you have
the right one. If it errors, stop — the key on this Mac is not the
right key for the repo, and the rest of this runbook depends on it.

Cross-check: the public half should match the `.sops.yaml` anchor:

```sh
age-keygen -y ~/mac-reset-bundle/sops-age-keys.txt
# Expected: age1z7fje8ex3nyl05f4e6e4y80klf783ala6gwyjnnt35hevcah2g2qvdutld
```

If the public key doesn't match `.sops.yaml`, this Mac has a stale or
unrelated age key and you need to find the real one before proceeding.

---

## Step 5 — Back up SSH + plant a recovery key

```sh
rsync -a --exclude='agent/' --exclude='*.sock' ~/.ssh/ ~/mac-reset-bundle/dot-ssh/
ls -la ~/mac-reset-bundle/dot-ssh/
```

The `--exclude` flags skip live `ssh-agent` sockets (e.g.,
`~/.ssh/agent/s.XXXX.agent.YYYY` from 1Password's SSH agent or
launchd). `cp -a` will print "is a socket (not copied)" warnings for
those — they're harmless (sockets are runtime IPC, not data), but
`rsync` keeps the output clean. The `ls` verifies that `id_*`,
`*.pub`, `config`, `known_hosts`, and `authorized_keys` (if present)
all landed.

Now add a **second** authorized key generated on the second device, so
that even if the bundle fails restore, you can still SSH into the
cluster:

1. On the phone (Termius / Blink) or other laptop, generate a fresh
   ed25519 key. Name it something like `recovery-2026`.
2. Append its public key to `~/.ssh/authorized_keys` on at least:
   - `root@lab-prox01` (`10.10.10.10`)
   - `raziel@lab-edge01` (or whichever cluster-management VM you use)
   - Each k3s control-plane node (`lab-cp01`..`lab-cp03`) — getting
     into one is enough to recover the kubeconfig from
     `/etc/rancher/k3s/k3s.yaml`.
3. Test: from the second device, SSH into each one **before** wiping
   the Mac. A key that's "added" but doesn't actually log in is worse
   than no key, because it gives false confidence.

The recovery key is not a long-term thing — remove it from
`authorized_keys` once the new Mac is rebuilt and verified.

---

## Step 6 — Back up the kubeconfig (skip if absent)

First, figure out whether a kubeconfig actually exists on this Mac.
It may not — if cluster operations have been done from `lab-edge01`
or a control-plane node over SSH, `~/.kube/config` was never created.

```sh
echo "KUBECONFIG=${KUBECONFIG:-not set}"
ls -la ~/.kube/ 2>/dev/null
find ~ -maxdepth 4 \( -name 'kubeconfig*' -o -name 'k3s.yaml' -o -path '*/.kube/*.yaml' \) 2>/dev/null
grep -nH 'KUBECONFIG' ~/.zshrc ~/.zshenv ~/.zprofile ~/.bashrc 2>/dev/null
```

The fourth line catches the case where `KUBECONFIG` is exported from
a shell rc file — without that export on the new Mac, restoring the
file alone won't make `kubectl` find it. The export line needs to
ride along in the bundle (either copy the rc file or note the export
for re-application during Step 16.3).

Three cases:

- **`KUBECONFIG` is set to a custom path** → back up that path:
  `cp -p "$KUBECONFIG" ~/mac-reset-bundle/kube-config && chmod 600 ~/mac-reset-bundle/kube-config`.
- **`~/.kube/config` exists** → standard path; copy it:
  `cp -p ~/.kube/config ~/mac-reset-bundle/kube-config && chmod 600 ~/mac-reset-bundle/kube-config`.
- **No kubeconfig anywhere** → expected if `kubectl` runs on
  `lab-edge01` instead of the Mac. Skip this step; record the fact
  in your notes so the post-reset rebuild doesn't waste time
  looking for it.

Either way, the kubeconfig is re-fetchable from any control-plane
node via `scp root@lab-cp01:/etc/rancher/k3s/k3s.yaml -`. If you
restore it onto a new Mac, rewrite the server address — k3s ships
the file with `server: https://127.0.0.1:6443`, which is meaningless
off-node:

```sh
# On the new Mac, after copying k3s.yaml down:
sed -i '' 's|server: https://127.0.0.1:6443|server: https://<lab-cp01-ip>:6443|' ~/.kube/config
```

---

## Step 7 — Terraform local state + provider lock files

Per `.gitignore`, `terraform.tfstate*` and `.terraform.lock.hcl` are
both ignored. State files are load-bearing; lock files prevent provider
version drift on the new Mac.

```sh
cd "$HOME/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
tar czf ~/mac-reset-bundle/terraform-local.tar.gz \
  $(find terraform -name 'terraform.tfstate*' -o -name '.terraform.lock.hcl' 2>/dev/null)
tar tzf ~/mac-reset-bundle/terraform-local.tar.gz
```

The third line is the proof: it should list at least
`terraform/cloudflare/terraform.tfstate` (or `.tfstate.backup`) and
`terraform/cloudflare/.terraform.lock.hcl`. If the listing is empty,
either state has been moved to a remote backend (in which case skip
this step) or it lives somewhere unexpected — locate it before
proceeding.

> **Note on this being load-bearing.** Local tfstate on a single
> workstation is the actual risk this runbook is mitigating. After
> the rebuild, consider moving state to a remote backend
> (`backend "s3"`, `backend "remote"`, or `backend "http"` against
> the cluster's own object store) so this risk goes away. That's an
> ADR-worthy decision, not a same-day change.

---

## Step 8 — Cloudflared local credentials (if any)

```sh
[ -d ~/.cloudflared ] && cp -a ~/.cloudflared ~/mac-reset-bundle/dot-cloudflared
```

If the directory doesn't exist, the connector only runs on
`lab-edge01` (per runbook 03 § 2.4) and there's nothing to back up
here. The tunnel credentials themselves are encrypted in the repo at
`ansible/group_vars/lab_edge/tunnel-creds.enc.json` and recoverable
via the age key from Step 4.

---

## Step 9 — Sundry tokens in env, dotfiles, .env

Tokens hide in shell rc files and per-project `.env`s. Grep first,
then copy what's relevant.

```sh
# Tokens, secrets, and load-bearing env exports (KUBECONFIG,
# SOPS_AGE_KEY_FILE, AWS_PROFILE, etc.) — grep wide, edit down later.
grep -iE '(token|secret|api[_-]?key|password|bearer|KUBECONFIG|SOPS_|AWS_|AZURE_|CLOUDFLARE_)' \
  ~/.zshrc ~/.zshenv ~/.zprofile ~/.bashrc 2>/dev/null \
  > ~/mac-reset-bundle/shell-tokens-grep.txt

# Also stash the rc files themselves — easier than re-grepping every
# missing export on the new Mac.
for f in ~/.zshrc ~/.zshenv ~/.zprofile ~/.bashrc; do
  [ -f "$f" ] && cp -p "$f" ~/mac-reset-bundle/$(basename "$f")
done

cp -p ~/.docker/config.json ~/mac-reset-bundle/docker-config.json 2>/dev/null

# Scratch values Terraform reads that live in no committed file or SOPS
# blob — e.g. ~/.scratch/tunnel-uuid, which the cloudflare TF_VAR_*
# incantation in runbook 05 `cat`s directly. Gitignored and
# workstation-local: if ~/.scratch/ exists, it MUST ride along, or the
# next rebuild loses it. (It is recoverable from terraform.tfstate as a
# last resort, but don't rely on that.)
[ -d ~/.scratch ] && cp -a ~/.scratch ~/mac-reset-bundle/dot-scratch
```

> **Capture the `SOPS_AGE_KEY_FILE` export explicitly.** sops on macOS
> defaults to `~/Library/Application Support/sops/age/keys.txt`, but this
> repo keeps the key under `~/.config` and depends on `SOPS_AGE_KEY_FILE`
> pointing there. That export must be in one of the rc files copied
> above — confirm with `grep -l SOPS_AGE_KEY_FILE ~/mac-reset-bundle/.z*`.
> If it isn't, Step 16.3 re-creates it anyway, but verify now rather than
> rediscovering it when `sops -d` fails post-reset.

For per-project `.env` files (macOS `cp` doesn't have `--parents`, so
use `rsync -R`):

```sh
cd "$HOME/Documents/Claude/Projects/Cucox Lab"
mkdir -p ~/mac-reset-bundle/dotenvs
find . -name '.env' -not -path '*/node_modules/*' -print0 | \
  xargs -0 -I {} rsync -R {} ~/mac-reset-bundle/dotenvs/
ls -la ~/mac-reset-bundle/dotenvs/
```

Open `shell-tokens-grep.txt` and skim — if a token shows up there, it
was probably exported from a `.env` file and only matters at
development time. Note which services they unlock so you remember to
re-export on the new Mac.

---

## Step 10 — Commit or stash in-flight repo work

Per project rules, this runbook does not run git. **You** should, now:

1. `git status` — review every modified file.
2. Decide per file: commit, stash, or discard.
3. For stashed work: `git stash push -u -m "pre-mac-reset 2026-MM-DD"`.
4. Capture stashes as patches into the bundle (stashes are local-only,
   they vanish on reset):

```sh
cd "$HOME/Documents/Claude/Projects/Cucox Lab/cucox-lab-infra"
git stash list | awk -F: '{print $1}' | while read s; do
  git stash show -p "$s" > ~/mac-reset-bundle/stash-$(echo "$s" | tr -d 'stash@{}').patch
done
```

(Stash entries by index are stable for the moment but get renumbered
as stashes are added/dropped — capture them now and don't add new
stashes between this step and the wipe.)

---

## Step 11 — Seal the bundle with a passphrase

**Do not** encrypt the bundle with the age key — the age key is inside
the bundle. Use passphrase encryption:

```sh
cd ~ && tar cf - mac-reset-bundle | age -p > mac-reset-bundle.tar.age
```

`age -p` prompts twice for a passphrase. Use a passphrase that:

- Lives in your password manager **on the second device** (so you can
  read it after the reset before the new Mac is set up).
- Is **not** the same as any service password.
- Is something you'd recognize if you saw it in 6 months.

Verify the seal works:

```sh
age -d ~/mac-reset-bundle.tar.age | tar tf - | head -20
```

If the listing looks right, the bundle is sealed. If `age -d` errors
or `tar tf -` prints garbage, redo this step before anything else.

---

## Step 12 — Two-copy rule

The encrypted bundle goes in **two** places. One drive failure
shouldn't equal total loss.

- **Copy A:** External drive (USB / SSD). Physical, offline.
- **Copy B:** One cloud location. Since it's already passphrase-
  encrypted, any provider is acceptable — iCloud Drive, Google Drive,
  Dropbox, S3, R2. Convenience wins.

Verify both copies are readable from a different device. Don't just
upload and assume.

---

## Step 13 — Restore-test from the second device

The whole point of this runbook. Before wiping the Mac, prove you can
get into every load-bearing system from somewhere else:

| What to test | How | Pass criterion |
|---|---|---|
| SSH to `lab-prox01` | Termius / phone, recovery key from Step 5 | Shell prompt |
| SSH to `lab-cp01` (or any k3s CP) | Same | Shell prompt; `cat /etc/rancher/k3s/k3s.yaml` works |
| Cloudflare dashboard | Browser on second device, TOTP from Step 2 | Logged in, can see the zone |
| UniFi controller | Local IP from on-network device, **and** Cloudflare-fronted URL | Logged in via at least one path |
| GoDaddy dashboard | Browser, TOTP from Step 2 | Logged in (still load-bearing pre-migration cutover) |
| GitHub push | `git push` from second device, with its own SSH key or PAT | Push succeeds (or dry-run with `--dry-run`) |
| Production ingress | Open `https://cucox.me` (or current live host) on cellular | Page loads; doesn't depend on Mac |
| Bundle decrypts | On second device: download Copy B, `age -d ... \| tar xf -` | Files extract |

Every row must pass. Each failure is a gap to fix before reset — that
is the entire reason for this step. Do **not** rationalize a failure
("I'll figure it out later"); later is after the wipe, when you
can't.

---

## Step 14 — Wipe local copies of the bundle

After the encrypted bundle is on the external drive **and** in cloud
storage, remove every plaintext and local copy from the Mac so the
factory reset can't be undone by someone pulling the SSD before the
wipe finishes.

```sh
# Plaintext working dir
rm -rf ~/mac-reset-bundle

# If you keep a local copy of the encrypted bundle on the Mac itself,
# also nuke that — chmod 600 first because rm -P checks write perms
# (see memory: feedback_macos_rm_secure_delete).
chmod 600 ~/mac-reset-bundle.tar.age 2>/dev/null && rm -P ~/mac-reset-bundle.tar.age 2>/dev/null
```

The `-P` flag overwrites file contents before unlinking on macOS. On
APFS with whole-volume encryption (FileVault), the factory reset
itself will rotate the volume key and render the old contents
unreadable, but defense in depth is cheap here.

---

## Step 15 — Now factory reset

Apple → System Settings → General → Transfer or Reset → **Erase All
Content and Settings**. This is the point of no return for anything
not in the encrypted bundle.

---

## Step 16 — Post-reset rebuild

Order matters. The age key must be in place **before** anything
touches the repo's encrypted files — otherwise sops fails, and you'll
chase phantom "the repo is broken" issues.

### 16.1 — Base tools

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install git age sops terraform kubectl ansible cloudflared jq
```

### 16.2 — Pull the encrypted bundle back

From iCloud Drive / external SSD / wherever Copy B lives. Decrypt:

```sh
cd ~ && age -d mac-reset-bundle.tar.age | tar xf -
```

`age` prompts for the passphrase from Step 11. If you can't remember
it, the bundle is effectively gone — this is the moment the
"passphrase in the password manager" decision from Step 11 pays off.

### 16.3 — Restore credentials in dependency order

```sh
# age key first — everything downstream needs it
mkdir -p ~/.config/sops/age
cp ~/mac-reset-bundle/sops-age-keys.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# sops on macOS defaults to ~/Library/Application Support/sops/age/keys.txt,
# NOT ~/.config. This repo keeps the key under ~/.config and relies on
# SOPS_AGE_KEY_FILE pointing there (see scripts/tf.sh). Without this
# export, `sops -d` in Step 16.4 fails with "no key could decrypt the
# data" even though the key file is perfectly fine.
grep -q SOPS_AGE_KEY_FILE ~/.zshrc 2>/dev/null || \
  echo 'export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"' >> ~/.zshrc
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"

# SSH
cp -a ~/mac-reset-bundle/dot-ssh ~/.ssh
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_* ~/.ssh/config ~/.ssh/known_hosts 2>/dev/null
chmod 644 ~/.ssh/*.pub 2>/dev/null

# kubeconfig
mkdir -p ~/.kube
cp ~/mac-reset-bundle/kube-config ~/.kube/config
chmod 600 ~/.kube/config

# Docker auth, if present
[ -f ~/mac-reset-bundle/docker-config.json ] && \
  mkdir -p ~/.docker && cp ~/mac-reset-bundle/docker-config.json ~/.docker/config.json
```

### 16.4 — Clone the repo and prove sops works

```sh
mkdir -p ~/Documents/Claude/Projects/Cucox\ Lab
cd ~/Documents/Claude/Projects/Cucox\ Lab
git clone <repo-url> cucox-lab-infra
cd cucox-lab-infra
sops -d terraform/cloudflare/secrets.enc.yaml | head -5
```

If `sops -d` prints decrypted content, the age key restore worked.
If it errors with "no key could decrypt the data", recheck Step 16.3
(`keys.txt` permissions, path) before going further.

### 16.4a — Rejoin the management network

The restored kubeconfig, Terraform state, and SSH config are all useless
if the Mac can't reach the lab. A factory reset wipes every saved Wi-Fi
network, so the rebuilt Mac will rejoin whatever it can — almost always
`HouseWiFi` (Default LAN), **not** the operator network.

Per ARCHITECTURE.md § 3.3.1 and § 3.5, there are two access paths to the
mgmt VLAN, and a reset breaks both:

- **Preferred:** join the `CucoxLab-Mgmt` SSID (WPA3-personal). This
  places the Mac *directly into* VLAN 10 — same VLAN as the Proxmox host
  — so no inter-VLAN firewall sits in the path. Confirm placement:

  ```sh
  ipconfig getifaddr en0          # expect a 10.10.10.x address
  nc -vz 10.10.10.10 8006         # expect "succeeded"
  ```

- **Fallback (HouseWiFi / Default LAN):** § 3.3.1 only permits Default
  LAN → mgmt on tcp/22,443,6443,8006 for the **single allowlisted
  operator IP**. The reset Mac gets a new DHCP lease (and a fresh
  macOS Private Wi-Fi MAC), so it no longer matches that rule. Symptom:
  `ping 10.10.10.10` works but TCP to `:8006` returns "no route to
  host". Fix in the UniFi UCG-Max controller: set the Mac's Wi-Fi MAC
  to fixed/hardware, add a DHCP reservation, and repoint the firewall
  rule's operator-IP object at the reserved address.

Do not proceed to 16.5/16.6 until `nc -vz 10.10.10.10 8006` succeeds —
every Terraform and `kubectl` step below depends on it.

### 16.5 — Restore Terraform state

```sh
cd ~/Documents/Claude/Projects/Cucox\ Lab/cucox-lab-infra
tar xzf ~/mac-reset-bundle/terraform-local.tar.gz
cd terraform/cloudflare
terraform init
terraform plan
```

**Expected:** `No changes. Your infrastructure matches the
configuration.` (or an equivalent zero-diff message).

**If `plan` proposes to create resources:** stop. State restore did
not work; running `apply` here would clobber the live Cloudflare
config. Recheck the tarball, the path, and that you're in the right
provider directory.

### 16.6 — Verify cluster access

```sh
kubectl get nodes -o wide
kubectl get pods -A | grep -vE 'Running|Completed' | head
```

Every node should be Ready; the second command should print only the
header (i.e., no non-Running pods). If a control-plane node is missing
from `get nodes`, the kubeconfig points at a host you can no longer
reach — check name resolution and that the cluster API endpoint
(usually `https://<vip>:6443`) is accessible from this Mac's VLAN.

### 16.7 — Verify Ansible reachability

```sh
cd ~/Documents/Claude/Projects/Cucox\ Lab/cucox-lab-infra
ansible -i ansible/inventory/hosts.yml all -m ping
```

Every host should respond `pong`. This validates the SSH restore end-
to-end.

> **The inventory must be in git.** `ansible/inventory/hosts.yml` is not
> a workstation secret and is not gitignored — it belongs in the repo.
> It was reconstructed on 2026-05-21 (from ARCHITECTURE.md § 4.4) after
> a rebuild found it missing entirely; it had never been committed, so
> nothing — neither git nor the backup bundle — had a copy. If `ansible`
> errors that the inventory doesn't exist, that regression has recurred:
> rebuild it from § 4.4 and **commit it this time**.

### 16.8 — Remove the recovery SSH key

Once everything above passes, remove the recovery key planted in
Step 5 from each host's `~/.ssh/authorized_keys`. The recovery key
is meant to be ephemeral; leaving it authorized is unmanaged trust.

### 16.9 — Securely delete the bundle from the new Mac

```sh
chmod 600 ~/mac-reset-bundle.tar.age && rm -P ~/mac-reset-bundle.tar.age
rm -rf ~/mac-reset-bundle
```

Cloud Copy B + external Copy A still exist — that's the offsite
backup going forward.

---

## Step 17 — Update memory / decide on remote state

After a successful rebuild, two follow-ups worth doing while the
experience is fresh:

1. **Move Terraform state to a remote backend.** The whole reason
   Step 7 exists is that local tfstate is workstation-bound. A
   remote backend (S3-compatible bucket on the cluster, Cloudflare R2,
   or Terraform Cloud) eliminates this risk for the next rebuild.
   This is an ADR-worthy decision; see `engineering:architecture`.
2. **Schedule a quarterly dry-run of Steps 1–13** (skip 14–16). The
   restore-test catches drift: a new TOTP-protected service added
   to the lab, a new host without the recovery key, an `.env` with
   tokens that wasn't in the inventory. Catching that during a
   non-emergency drill is the whole point.

---

## Common pitfalls

- **Backing up the age key with age.** Chicken and egg — if the
  bundle that contains the age key is itself encrypted with the age
  key, the key is unrecoverable. Always passphrase-encrypt the bundle
  (Step 11).
- **"FileVault encrypts the disk, so I don't need to be careful with
  the bundle."** FileVault protects against someone reading the SSD
  after the Mac is off. It does *nothing* against you copying the
  bundle to iCloud Drive in plaintext, where Apple can read it.
  Encrypt at the file layer, not just the disk layer.
- **Trusting iCloud Keychain to have synced SSH keys.** iCloud
  Keychain does not sync `~/.ssh/`. It syncs Safari passwords and
  Wi-Fi. Many people learn this on the new Mac.
- **Skipping the restore-test (Step 13) because "I'm in a hurry".**
  The restore-test is the only mechanism that catches a gap *before*
  the wipe. Skipping it converts a 60-minute prep into a multi-day
  recovery.
- **Assuming `cp -a` preserves macOS extended attributes for SSH
  keys.** `cp -a` is fine on macOS for this purpose — but verify
  permissions after restore (`ls -l ~/.ssh`) because some restore
  paths (especially via cloud sync) drop the executable bit and the
  600 mode.
- **Forgetting the Mac's network identity is part of the rebuild.**
  This runbook restores *files*, but cluster access also depends on the
  Mac being on the right VLAN with an allowlisted IP (§ 16.4a). A
  textbook-perfect file restore still can't reach Proxmox if the Mac
  rejoined `HouseWiFi` instead of `CucoxLab-Mgmt`. "`ping` works but the
  port is refused" is the tell — see 16.4a.
- **`sops -d` fails right after a clean restore.** Almost always the
  `SOPS_AGE_KEY_FILE` export is missing from the new shell, not a bad
  key — macOS sops looks under `~/Library/Application Support`, not
  `~/.config`. Step 16.3 sets the export; if you skipped it, `export
  SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"` and retry.

---

## Cross-references

- `00c-power-failure-recovery.md` — companion operations runbook for
  cluster-side recovery; complementary failure mode.
- `02-phase1-k3s-cluster.md` § 1 — where the k3s join token (encrypted
  via the age key being protected here) is documented.
- `03-phase2-cloudflared-tunnel.md` § 2.4 — where the tunnel
  credentials JSON (also age-encrypted) is documented.
- `05-dns-godaddy-to-cloudflare.md` and 05a/05b — context for why
  GoDaddy + Cloudflare access are both load-bearing during the
  migration window.
- `.sops.yaml` — canonical record of the age public key the bundle
  must match. If the public key derived from your `keys.txt` doesn't
  match the recipient in `.sops.yaml`, you have the wrong key.
