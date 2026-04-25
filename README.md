# cucox-lab-infra

Infrastructure-as-code, runbooks, and architecture documentation for the Cucox
Lab — a self-hosted, on-prem cluster designed as a learning platform for
distributed systems, data-intensive applications, and HPC-adjacent systems
engineering work.

## Layout

```
.
├── ARCHITECTURE.md            # Canonical design document. Read this first.
├── docs/
│   ├── runbooks/              # Step-by-step procedures (00-, 01-, ...).
│   └── decisions/             # ADRs (architecture decision records).
├── terraform/                 # VM provisioning (Proxmox provider).
├── ansible/                   # In-VM configuration (k3s, hardening, etc.).
├── k8s/                       # Kubernetes manifests / Helm values.
├── cloudflared/               # Tunnel config and ingress definitions.
└── scripts/                   # One-off helpers.
```

## Working agreement

- **Cowork (Claude in this chat)** is the architect: produces design docs,
  IaC, manifests, and runbooks. Does not execute against your hardware.
- **Claude Code on the Mac Air** is the operator: runs SSH, `terraform apply`,
  `kubectl`, `ansible-playbook` against your real cluster. Reads from this
  repo as source of truth.
- This repo is the handoff. Cowork writes; Code applies.

## Getting started

Read in order:

1. [`ARCHITECTURE.md`](./ARCHITECTURE.md) — what we're building and why.
2. [`docs/runbooks/00-phase0-proxmox-bootstrap.md`](./docs/runbooks/00-phase0-proxmox-bootstrap.md) — first concrete actions.

## Conventions

- Markdown for all docs. Commit messages follow Conventional Commits.
- Every architectural decision gets an ADR in `docs/decisions/`.
- Every multi-step procedure becomes a runbook in `docs/runbooks/`.
- Secrets are never committed. See `ARCHITECTURE.md` § Secrets Management.
