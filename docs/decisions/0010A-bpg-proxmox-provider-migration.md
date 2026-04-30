# ADR-0010-A — Migration from Telmate/proxmox to bpg/proxmox

| | |
|---|---|
| **Status** | Active |
| **Date** | 2026-04-29 |
| **Deciders** | Raziel |
| **Amends** | [ADR-0010](./0010-terraform-proxmox-provider.md) — fires the migration trigger named there. |

## Context

[ADR-0010](./0010-terraform-proxmox-provider.md) chose `Telmate/proxmox`
(pinned `~> 2.9.14`) and named explicit revisit triggers. The first one:

> A bug in Telmate prevents an action we need that's already shipped in
> `bpg`, and no acceptable workaround exists.

That trigger fired on 2026-04-29 during the first `terraform apply` of
the six Phase 1 VMs:

```
Stack trace from the terraform-provider-proxmox_v2.9.14 plugin:
panic: interface conversion: interface {} is string, not float64
goroutine 55 [running]:
github.com/Telmate/proxmox-api-go/proxmox.NewConfigQemuFromApi(...)
        github.com/Telmate/proxmox-api-go@v0.0.0-20230319185744-e7cde7198cdf/proxmox/config_qemu.go:584
github.com/Telmate/terraform-provider-proxmox/proxmox.resourceVmQemuCreate(...)
Error: The terraform-provider-proxmox_v2.9.14 plugin crashed!
```

Diagnosis: `proxmox-api-go@2023-03-19` was built against the Proxmox 7.x
API. The current Proxmox host (PVE 8.x) returns at least one config
field as a string where Telmate's parser does an unchecked type
assertion to `float64`. The panic is in the provider's `NewConfigQemuFromApi`
read-back path, after VM creation. There is no resource-block setting
that bypasses a panic inside the provider's Go code.

Telmate v2.9.14 is the latest 2.9.x patch; the project's next branch is
v3.x, which is itself a breaking rewrite. Either route requires
substantial Terraform code changes. Given the cost-equivalence and
ADR-0010's explicit guidance on this case, we migrate to `bpg/proxmox`.

## Decision

**Migrate to `bpg/proxmox`**, pinned to `~> 0.66`. ADR-0010's "Why we'd
switch" list is now active history; this ADR records the migration
itself.

Concrete changes:

| Area | Before (Telmate v2.9.14) | After (bpg v0.66) |
|---|---|---|
| Provider source | `Telmate/proxmox` | `bpg/proxmox` |
| Provider auth | `pm_api_url` + `pm_api_token_id` + `pm_api_token_secret` (three fields) | `endpoint` + `api_token` (joined string `<id>=<secret>`) + `insecure` |
| Endpoint format | `https://10.10.10.10:8006/api2/json` | `https://10.10.10.10:8006/` (no `/api2/json` suffix) |
| Resource type | `proxmox_vm_qemu` | `proxmox_virtual_environment_vm` |
| Clone source | `clone = "tmpl-ubuntu-24-04"` (by name) | `clone { vm_id = 9000 }` (by VMID, in a block) |
| CPU / memory | flat `cores` + `sockets` + `memory` | nested `cpu { ... }` and `memory { ... }` blocks |
| Network | `network { bridge = ... }` (top-level) | `network_device { bridge = ... }` (renamed; can repeat for multi-NIC) |
| Cloud-init | flat `ipconfig0`, `ciuser`, `sshkeys`, `nameserver`, `cicustom` | nested `initialization { ip_config { ipv4 { ... } } user_account { ... } dns { ... } vendor_data_file_id = ... }` |
| Cicustom equivalent | `cicustom = "vendor=local:snippets/cucox-base.yaml"` | `vendor_data_file_id = "local:snippets/cucox-base.yaml"` |
| Disk size override on clone | `disk { size = "40G" }` | `disk { size = 40 }` (number, not string) |

The `cucox-base.yaml` snippet (Phase 1 § 5.0) is unchanged — it's just
referenced by a different argument name.

The Proxmox API token created in Phase 1 § 1.1 (`terraform@pve!provider`,
role `TerraformProv`) is reused. The role's privilege set is sufficient
for both providers; no token rotation needed.

## Rationale

### Why not Telmate v3.x

Three reasons:

1. v3 is a breaking rewrite. Migrating to v3 costs the same Terraform
   code rework as migrating to bpg, with no offsetting benefit.
2. Telmate's release cadence remains slow; the underlying compat-with-
   Proxmox-version risk is structural, not specific to v2.9.14.
3. ADR-0010 specifically named bpg as the alternative if Telmate
   misbehaves. Honoring that named alternative gives the audit trail a
   straight line.

### Why bpg

- Active maintenance: monthly-ish releases, tested against current
  Proxmox 8.x.
- Cleaner resource model: nested blocks group related concerns
  (`cpu { }`, `memory { }`, `clone { }`, `initialization { }`) instead
  of flattening fifty attributes onto one resource.
- First-class `vendor_data_file_id` for `cicustom` semantics.
- Better error messages on `terraform plan`.

### What we accept

- More verbose HCL (nested blocks vs flat attributes). For 6 VMs this
  is ~30 extra lines; for 60 VMs it would matter more.
- Slight retraining cost — every Telmate-specific tutorial / Stack
  Overflow answer no longer applies. Mitigation: the bpg docs are
  good and the resource-shape mapping is mechanical (see table above).
- `bpg/proxmox` is `0.x`. Backwards-incompat changes in minor versions
  are possible. Mitigation: pin to `~> 0.66` in `versions.tf`; review
  release notes before bumping.

## Consequences

- All Phase 1 VM management is now done via bpg.
- The role `TerraformProv` and the API token `terraform@pve!provider`
  are reused. The token format in `secrets.auto.tfvars.enc.yaml`
  changes from two fields to one joined string.
- Any future provider-touching ADRs reference this one, not ADR-0010.
- ADR-0010 status is amended to reflect that the revisit trigger fired
  and which alternative was chosen.

## What this ADR does not do

- It does not retract ADR-0010. ADR-0010 remains the historical record
  of the original choice, the trade-offs considered, and the explicit
  revisit triggers that made this migration possible without a fresh
  decision-from-scratch.
- It does not commit to bpg forever. If bpg's maintenance regresses or
  a new provider supersedes it, the same revisit-trigger pattern from
  ADR-0010 applies — write ADR-0010-B at that point.

## References

- [ADR-0010](./0010-terraform-proxmox-provider.md) — the original choice
  and the revisit triggers this ADR fires.
- bpg/proxmox provider: https://github.com/bpg/terraform-provider-proxmox
- Telmate panic upstream context: known compat issue between
  `proxmox-api-go@2023-03-19` and Proxmox VE 8.x.
- `docs/runbooks/01-phase1-vm-bringup.md` § 5 — implementation.
