#!/usr/bin/env bash
# Wrapper for terraform plan/apply/destroy that decrypts the SOPS-encrypted
# Proxmox API token at runtime and passes it as -var arguments.
#
# Usage:
#   scripts/tf.sh plan
#   scripts/tf.sh apply
#   scripts/tf.sh destroy -target=proxmox_vm_qemu.vm[\"lab-wk02\"]
#
# Requires: terraform, sops, yq, jq, and an age key at $SOPS_AGE_KEY_FILE
# (defaults to ~/.config/sops/age/keys.txt).
#
# See docs/runbooks/01-phase1-vm-bringup.md § 6.2 / § 6.3 for context.

set -euo pipefail

: "${SOPS_AGE_KEY_FILE:=$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/proxmox"

cd "$TF_DIR"

# Sanity checks.
for cmd in terraform sops yq jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: $cmd not on PATH. brew install $cmd" >&2
    exit 1
  }
done

if [[ ! -f "$SOPS_AGE_KEY_FILE" ]]; then
  echo "error: age key not found at $SOPS_AGE_KEY_FILE" >&2
  echo "Set SOPS_AGE_KEY_FILE or generate with: age-keygen -o ~/.config/sops/age/keys.txt" >&2
  exit 1
fi

if [[ ! -f secrets.auto.tfvars.enc.yaml ]]; then
  echo "error: secrets.auto.tfvars.enc.yaml not found in $TF_DIR" >&2
  echo "See runbook 01 § 1.2 to create it." >&2
  exit 1
fi

# macOS Gatekeeper occasionally re-quarantines cached provider binaries after
# OS updates, breaking `terraform apply` with a cryptic "Failed to read any
# lines from plugin's stdout" error. Strip extended attrs from .terraform/ on
# every invocation — cheap, idempotent, and prevents a 30-min debug session.
# No-op on Linux (xattr is macOS-specific). See runbook 01 gotcha row.
if [[ "$(uname)" == "Darwin" && -d .terraform ]]; then
  xattr -cr .terraform/ 2>/dev/null || true
fi

# Decrypt secrets to a temp file with restrictive perms; clean up on exit.
SECRETS=$(mktemp -t pmsecrets.XXXX.json)
chmod 600 "$SECRETS"
trap 'rm -f "$SECRETS"' EXIT

sops --decrypt secrets.auto.tfvars.enc.yaml | yq -o=json > "$SECRETS"

# Pass everything after the first arg through to terraform unchanged.
# Variable shape per ADR-0010-A (bpg/proxmox provider).
terraform "$@" \
  -var "proxmox_endpoint=$(jq -r .proxmox_endpoint "$SECRETS")" \
  -var "proxmox_api_token=$(jq -r .proxmox_api_token "$SECRETS")" \
  -var "proxmox_tls_insecure=$(jq -r .proxmox_tls_insecure "$SECRETS")"
