# ADR-0010 — Terraform provider for Proxmox: `Telmate/proxmox`

| | |
|---|---|
| **Status** | **Superseded by [ADR-0010-A](./0010A-bpg-proxmox-provider-migration.md)** on 2026-04-29. Revisit trigger #1 (Telmate bug, no workaround) fired during first `terraform apply`. |
| **Date** | 2026-04-26 |
| **Deciders** | Raziel |
| **Supersedes** | — |

## Context

ARCHITECTURE.md § 8.1 commits the lab to managing VM lifecycle on Proxmox
via Terraform. Two providers are realistic candidates as of April 2026:

| Provider | Source | Maintainer model | Notes |
|---|---|---|---|
| `Telmate/proxmox` | github.com/Telmate/terraform-provider-proxmox | Community, slow but sustained | The "default" provider in most Proxmox+Terraform tutorials; pinned by ARCHITECTURE.md from day one. |
| `bpg/proxmox` | github.com/bpg/terraform-provider-proxmox | Single very active maintainer + community | Newer, strong Proxmox 8.x coverage, cleaner cloud-init / file-management resources, faster release cadence. |

Both work. The choice has consequences for how Phase 1 (and any future
provider-driven work) is written. Switching providers later is a
non-trivial state-rewrite — `terraform state mv` does not cross provider
boundaries — so we pick deliberately rather than discovering the choice
through inertia.

## Decision

Continue with **`Telmate/proxmox`**, pinned to the `2.9.x` release line in
`terraform/proxmox/versions.tf`. `bpg/proxmox` is documented here as the
explicit alternative and the migration path; we adopt it only if a
specific blocker forces it.

## Rationale

### Why stay on Telmate

1. **ARCHITECTURE.md alignment.** The architecture document was authored
   against Telmate. Switching providers in the same week we're standing
   up Phase 1 would mean rewriting examples, runbooks, and worked configs
   without any workload-driven reason. Documentation drift is a real
   cost.

2. **The lab's primary value is learning, not optimality.** Telmate has
   well-known rough edges (cloud-init disk-bus quirks, occasional MAC
   regeneration drift, slower support for new Proxmox features). Working
   *through* those rough edges is itself instructive — provider authoring,
   `terraform plan` diff reading, lifecycle ignore-changes patterns. A
   too-polished provider hides the seam between Terraform-state and
   Proxmox-state where the interesting failure modes live.

3. **Tutorial gravity.** Most current Proxmox-homelab content (blogs,
   YouTube, ChatGPT/Claude completions trained pre-2026) assumes Telmate.
   When something breaks at 11pm, the search-engine surface area for
   "Telmate proxmox cloud-init not applying" is materially larger than
   the equivalent for `bpg`. For a single-operator lab this matters.

4. **Pin discipline mitigates the maintenance gap.** Telmate's slower
   releases are only a problem if we're chasing a moving target. We're
   not — we pin to a known-good release and revisit deliberately.

### Why we'd switch (revisit triggers)

We move to `bpg/proxmox` if **any one** of these becomes true:

- A bug in Telmate prevents an action we need that's already shipped in
  `bpg`, and no acceptable workaround exists. Examples that would qualify:
  ZFS-native zvol resize bugs, Proxmox 9.x compatibility (when it lands),
  or cloud-init `userdata` injection failures on `network: v2` configs.
- Telmate goes ≥ 12 months without a release while `bpg` continues to
  track Proxmox upstream — i.e., the project is effectively unmaintained.
- We need a provider-native primitive (e.g. `proxmox_virtual_environment_file`
  for ISO management) that Telmate doesn't expose at all and that we can't
  reasonably replace with a `null_resource` + remote-exec.
- The Phase 5 GPU-passthrough work surfaces a Telmate gap that requires
  either upstream patches or a fork.

If a trigger fires, the migration is documented as ADR-0010-A.

### Risks accepted by this decision

- **Slower feature parity with new Proxmox releases.** Mitigation: pin
  Proxmox VE major versions in lockstep with the provider. Don't upgrade
  Proxmox before checking Telmate has a tagged release that supports it.
- **MAC address drift on network blocks.** Mitigation: the Phase 1
  Terraform uses `lifecycle { ignore_changes = [network] }` — documented
  in `terraform/proxmox/main.tf` and runbook 01.
- **Cloud-init disk on `ide2` only.** Mitigation: the golden template
  is built with `--ide2 tank-vmdata:cloudinit` (runbook 01 Step 3.2). If
  this changes upstream, we'll catch it on the next `terraform plan`.

## Consequences

- Pin in `versions.tf`:

  ```hcl
  required_providers {
    proxmox = { source = "Telmate/proxmox", version = "~> 2.9.14" }
  }
  ```

- The Phase 1 runbook (`docs/runbooks/01-phase1-vm-bringup.md`) is written
  against Telmate's resource shapes (`proxmox_vm_qemu`).
- Any Phase 5 ADR that depends on a provider-native feature must check
  Telmate first; if absent, that ADR is the one that triggers the
  migration, not this one.
- Reviewing this ADR is a 12-month item on the lab's quiet-time backlog
  (no specific date — when the next provider-touching change comes up).

## Alternatives considered

### `bpg/proxmox`

What it offers over Telmate:

- Active maintenance with monthly-ish releases tracking Proxmox 8.x.
- First-class file-upload resource (`proxmox_virtual_environment_download_file`)
  that would let us manage the Ubuntu cloud image as Terraform state
  rather than a `wget` step in the runbook.
- Cleaner cloud-init resource model — separate `cloud_init` blocks
  instead of overloading the disk schema.
- Better error messages on `terraform plan`.

Why not adopted today: the costs (rewriting ARCH and runbooks, walking
back tutorial-aligned examples, re-doing Phase 1 mid-stream) outweigh
the benefits for this iteration. This ADR explicitly leaves the door
open.

### Manual `qm` everywhere, no Terraform

Would shorten Phase 1 by a day. Permanently rejected by ARCHITECTURE.md
§ 4.3 — VMs are IaC after Phase 0. The template itself is the only
manually-built artifact; everything downstream is cloned by Terraform.

### Pulumi / Crossplane

Not evaluated. Not because they're bad, but because adding a third tool
in the IaC layer (Terraform + Ansible already; see ARCH § 8.1) is a poor
trade for a single-operator lab.

## References

- Telmate provider: https://github.com/Telmate/terraform-provider-proxmox
- bpg provider: https://github.com/bpg/terraform-provider-proxmox
- ARCHITECTURE.md § 4.3 (VM template strategy), § 4.4 (VM inventory),
  § 8.1 (Tooling).
- Runbook `01-phase1-vm-bringup.md` — concrete usage of this decision.
