# ADR-0003 — Secrets management: SOPS + age

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-25 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

The `cucox-lab-infra` repository is public on GitHub (see ADR-0008). It
contains Terraform code, Ansible playbooks, Helm values, and runbooks — and
therefore inevitably touches secrets: k3s join tokens, Cloudflare API tokens,
database passwords, the cloudflared tunnel credential, and any future
application secrets.

Secrets must be:

- **Stored in the repo** (so IaC is self-contained and reproducible), but
  **never in plaintext** (the repo is public).
- **Decryptable by the operator** with minimal tooling — no running daemon,
  no network call to a remote vault on every `terraform plan` or Ansible run.
- **Auditable** — it must be obvious which files in the repo are encrypted and
  which are not.
- **Git-diff-friendly** — encrypted files should produce meaningful diffs so
  PR review remains useful.

Alternatives evaluated:

1. **HashiCorp Vault** — production-grade secret store with dynamic secrets,
   leasing, and fine-grained policies. Requires a running server, HA setup
   for production use, and significant operational overhead. Overkill for a
   solo-operator homelab where the secret surface is small and static.
2. **1Password Secrets Automation** — SaaS-backed; requires a 1Password
   Teams/Business subscription and a running `op` agent. External dependency
   for a lab designed to minimize external dependencies. Adds cost.
3. **SOPS + age** — SOPS (Secrets OPerationS) is a file-level encryption tool
   that encrypts only the values in YAML/JSON/ENV files, leaving keys
   plaintext for readability. `age` is a modern, simple encryption tool
   (replaces GPG for this use case). No daemon, no network, one binary each.
4. **git-crypt** — encrypts entire files rather than individual values.
   Loses diff-ability; the entire file is an opaque blob in `git diff`.
   Harder to audit which files are protected.

## Decision

**SOPS + age** is the secrets management approach for all secrets that live
in the repository.

One age keypair per operator. The public key is committed in `.sops.yaml` as
the encryption recipient; the private key lives at
`~/.config/sops/age/keys.txt` on the operator machine and is backed up to
1Password.

The following secret categories are encrypted with SOPS before commit:

- Ansible vars files matching `*.secrets.yml`
- Kubernetes `Secret` manifests
- The Cloudflare API token (used by Terraform)
- The k3s join token
- Database passwords
- Any future application credential

The following are **never committed**, even encrypted (see ADR-0008):

- The cloudflared tunnel credentials JSON
- The age private key itself
- The Cloudflare Global API Key

## Rationale

### Why not Vault

Vault is the right answer for a team or a multi-operator production
environment. For a single-operator homelab, it introduces an availability
dependency: if the Vault cluster is down (it needs its own HA, storage, and
unsealing procedure), nothing that depends on dynamic secrets can run. The
operational complexity of running Vault correctly (auto-unseal, snapshots,
policy management) rivals the complexity of the lab itself. The learning
value is not worth the operational cost at this stage.

### Why not 1Password

1Password is already used for backup storage of the age private key. But using
it as the IaC secret backend would introduce a SaaS dependency and require the
`op` CLI agent to be running during every Terraform and Ansible execution.
The lab's design principle is that it should be operable from any machine with
`brew install sops age terraform ansible` — no external service dependency for
the control plane.

### Why SOPS over git-crypt

git-crypt encrypts entire files. This means `git diff` shows binary garbage
for any change to a secret file, PR review is blind to what changed, and
accidental plaintext commits to the wrong file path are hard to audit.

SOPS encrypts only the values, leaving the keys visible:

```yaml
# example: encrypted Ansible vars file
db_password: ENC[AES256_GCM,data:abc123...,tag:xyz==,type:str]
db_host: lab-db01.lab.cucox.local   # plaintext — not a secret
```

`git diff` on a SOPS file shows which keys changed (even if the new value is
still opaque), making PR review meaningful. `sops --decrypt` is one command
to view or edit.

### Why age over GPG

GPG has a large attack surface, complex key management (keyring, trust model,
expiry), and is notoriously easy to misconfigure. `age` is purpose-built for
symmetric and asymmetric encryption with a minimal API: `age-keygen` to create
a keypair, `age -r <pubkey>` to encrypt, `age -d` to decrypt. SOPS has
first-class `age` support alongside PGP and KMS backends. For a homelab,
`age` is the right tool.

## Consequences

### Positive

- Secrets live in the repo alongside the code that uses them — IaC is
  fully self-contained and reproducible on any machine with the age key.
- No daemon, no network call — decryption works fully offline.
- SOPS value-level encryption preserves file structure; `git diff` and PR
  review remain useful.
- Pre-commit `gitleaks` hook catches any accidental plaintext leakage before
  push (belt-and-suspenders alongside SOPS).
- `sops -e -i file.yaml` / `sops -d file.yaml` is the entire operator
  workflow — minimal learning curve.
- Rotation is a `sops updatekeys` command followed by a commit.

### Negative / trade-offs

- **Single point of key failure.** If the age private key is lost, all
  encrypted secrets in the repo are unrecoverable. Mitigated by 1Password
  backup. Procedure for key rotation is documented in a future runbook.
- **No dynamic secrets.** SOPS encrypts static values. For a future phase
  where database credentials need to rotate automatically (e.g., on a
  schedule), SOPS is insufficient and a Vault or external-secrets-operator
  approach may be needed. This is an acceptable Phase 0–4 limitation.
- **Operator discipline required.** SOPS only works if the operator
  consistently runs `sops -e` before committing. The pre-commit `gitleaks`
  hook is the backstop, not the primary control. A lapse in discipline is
  a real (if low-probability) risk.
- **No access controls within the repo.** Any operator with the age key can
  decrypt any secret. For a solo-operator lab this is fine; for a future
  multi-operator setup, SOPS supports multiple recipients with per-path
  key routing.

## Bootstrap

```sh
brew install sops age
age-keygen -o ~/.config/sops/age/keys.txt
# Copy the public key from the output into .sops.yaml as the recipient.
# Back up ~/.config/sops/age/keys.txt to 1Password immediately.
```
