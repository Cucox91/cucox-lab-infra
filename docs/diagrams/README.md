# Diagrams

Visual companions to [`ARCHITECTURE.md`](../../ARCHITECTURE.md) and the
runbooks. Files are dual-format: the `.drawio` is the editable source (open in
[draw.io desktop](https://github.com/jgraph/drawio-desktop) or
[diagrams.net](https://app.diagrams.net)), the `.svg` is a static rendering
committed alongside it for inline embedding and PR review without a draw.io
viewer.

## Index

| File | Scope | Anchored in |
|---|---|---|
| [`cucox-lab-architecture.drawio`](./cucox-lab-architecture.drawio) / [`.svg`](./cucox-lab-architecture.svg) | Phase 1 / Phase 2 target state — full lab end-to-end (Internet → Cloudflare → UCG-Max → Proxmox host → 3 VLANs → k3s cluster → workloads → storage). | `ARCHITECTURE.md` §0 "Architecture at a glance" |

## Conventions

- **Source-of-truth pair.** Every diagram has two files in this folder: a
  `.drawio` (editable) and a `.svg` (rendered). They share a basename. When
  updating a diagram, edit the `.drawio` in draw.io, then export an updated
  SVG to the same path before committing — never let the two drift.
- **Embed in markdown** with: `![alt text](./docs/diagrams/<name>.svg)` from
  the repo root, or relative paths from runbooks.
- **Caption every embed** with one line stating the scope and the
  ARCHITECTURE.md section it supports. Diagrams without a caption are
  decorative; diagrams without an anchor get stale fast.
- **One diagram, one purpose.** When a diagram crosses three concerns, split
  it. The lab-wide diagram intentionally compresses everything to one page
  for orientation; deeper concerns (firewall matrix, storage layout, request
  flow) get their own files.

## Planned diagrams (not yet drawn)

| Filename | Purpose | Trigger to draw |
|---|---|---|
| `ucg-zone-matrix.drawio` | Full UniFi Zone-Based Firewall matrix — every zone-pair cell with ordered rules, Local-In + Inter-VLAN distinguished. | Before ADR-0013 is finalized; pairs with the ZBF gotcha runbook. |
| `request-flow-external.drawio` | Sequence diagram: browser → Cloudflare edge → Tunnel → cloudflared → ingress-nginx → Service → Pod, including TLS boundaries. | Phase 2, when the first Tunnel terminates at ingress. |
| `storage-layout.drawio` | ZFS dataset map — which workload classes land on `rpool` vs `tank`, snapshot schedule, recordsize choices. | When Longhorn lands (Phase 4) and the storage class story stops being trivial. |
| `phase5-arm-expansion.drawio` | Pi5/Pi5/Pi4 joining as ARM workers + GPU-passthrough VM topology + Mac Mini build runner wiring. | Phase 5 kickoff. |
| `secrets-flow.drawio` | SOPS+age envelope — operator key → repo-encrypted file → decrypt site (operator workstation, never a server) → consumer (Ansible/k8s Secret). | When an ADR for secret rotation is filed. |

## Authoring notes

- Keep canvas size sane (~1700×2000 for a "full lab" diagram, smaller for
  focused ones). draw.io's PDF export at this size is sharp but the SVG is
  what we commit.
- Stick to the existing palette so the diagram set looks like a family:
  blue for network, green for mgmt/operator path, red for dmz / hard-deny,
  yellow for storage / annotation, purple for client devices, orange for
  Cloudflare. The lab-wide diagram defines the canonical use of each.
- Containers (swimlanes) > free-floating shapes. Anything sitting outside a
  container is implicitly "global" and reads as out-of-scope.
- If you find yourself labeling an arrow with more than ~6 words, that label
  belongs in a sticky-note shape near the arrow, not on the arrow itself.
