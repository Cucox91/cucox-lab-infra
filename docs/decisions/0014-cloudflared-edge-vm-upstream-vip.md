# ADR-0014 — Cloudflared (Phase 2) targets the ingress VIP directly, not the in-cluster Service DNS

> **Status:** Active (deviation, time-boxed)
> **Date:** 2026-05-01
> **Supersedes:** none
> **Superseded by:** none (yet — see "Closes when" below)
> **Owner:** Raziel

## Context

[ARCH § 6.3](../../ARCHITECTURE.md) sketches `cloudflared/config.yaml`
with the upstream service set to
`https://ingress-nginx.ingress.svc.cluster.local`. That sketch
implicitly assumes the **Phase 5 plan** from ARCH § 6.1: cloudflared
running as a Deployment **inside** the k3s cluster, where the
`*.svc.cluster.local` DNS suffix resolves via CoreDNS.

In Phase 2, [runbook 03](../runbooks/03-phase2-cloudflared-tunnel.md)
deploys cloudflared on `lab-edge01` — a dedicated VM in the **dmz**
VLAN, **outside** the cluster. From dmz, `*.svc.cluster.local` does
not resolve (it's a CoreDNS-internal name only reachable from pods).
The architectural intent — "send tunnel traffic to ingress-nginx" —
must be preserved through some other mechanism.

## Decision

In Phase 2, cloudflared on `lab-edge01` targets the **ingress-nginx
MetalLB VIP at `https://10.10.20.50:443`** as its upstream.

`10.10.20.50` is pinned for ingress-nginx in
[runbook 02 § 6.1](../runbooks/02-phase1-k3s-cluster.md) via the
`metallb.universe.tf/loadBalancerIPs` annotation. It's the stable,
documented endpoint for "send L7 traffic into the cluster" from
outside.

Per-route configuration in
[`cloudflared/config.yaml.tmpl`](../../cloudflared/config.yaml.tmpl)
(materialized into `/etc/cloudflared/config.yaml` on `lab-edge01`)
includes:

- `service: https://10.10.20.50:443` — the upstream
- `originRequest.noTLSVerify: true` — ingress-nginx terminates TLS with
  a self-signed cert; cert-manager + Let's Encrypt is a Phase 3 follow-up
- `originRequest.httpHostHeader: <hostname>` per route — without this,
  cloudflared would send `Host: 10.10.20.50` to nginx, which would not
  match any `Ingress` rule (those match on the public hostname)

## Consequences

### Positive

- Phase 2 is unblocked. The architectural intent is preserved without
  requiring cloudflared to run in-cluster.
- The ingress VIP is a stable, documented Phase 1 artifact — no new
  infrastructure introduced.
- `lab-edge01` as a dedicated DMZ VM keeps the cluster's external
  attack surface explicit (one VM, one daemon, one outbound flow).

### Negative

- Per-route `httpHostHeader` is mandatory. Forgetting it for a new
  hostname produces 404s with no obvious cause until you compare logs.
  Mitigated by `cloudflared/config.yaml.tmpl` template comments.
- `noTLSVerify: true` accepts the ingress-nginx self-signed cert
  unconditionally. A man-in-the-middle on the cluster VLAN could
  intercept tunnel-to-ingress traffic. Mitigated by:
  - The cluster VLAN is L2-only and operator-controlled
  - The Lab-DMZ → Lab-Cluster firewall cell allows only `tcp/443` to
    `10.10.20.50/32`, not arbitrary cluster IPs
  - Phase 3 cert-manager + Let's Encrypt closes this — proper TLS chain
    means `noTLSVerify` can flip to `false`
- The runbook 03 config diverges from ARCH § 6.3's sketch. Anyone
  reading ARCH alone would expect `*.svc.cluster.local`. ADR-0014
  bridges the gap.

## Closes when

This deviation closes when the **Phase 5 plan** from ARCH § 6.1 is
executed: `cloudflared` moves into the cluster as a Deployment with
replicas across worker nodes for HA. At that point:

- `service:` switches from `https://10.10.20.50:443` to
  `https://ingress-nginx.ingress.svc.cluster.local`
- `httpHostHeader` is no longer needed (the in-cluster Service
  abstraction handles `Host` differently — Kubernetes Service DNS
  + `kube-proxy` / Cilium routing preserves the original Host header
  the client sent)
- `noTLSVerify` may stay or go depending on whether cert-manager
  has landed by then
- `lab-edge01` either retires or repurposes (e.g. as a second
  cloudflared replica running outside the cluster for redundancy)

A successor ADR will be filed at that time recording the migration
and superseding this one.

## Alternatives considered

- **Run a coredns-side stub** that forwards `*.svc.cluster.local`
  queries from `lab-edge01` to the in-cluster CoreDNS via the Lab-Mgmt
  zone. Rejected: requires opening dmz → mgmt or dmz → cluster:53
  flows that ARCH § 3.3.1 explicitly denies, weakening the network
  posture for marginal gain.
- **Move cloudflared into the cluster now** (skip Phase 2's edge VM
  pattern, jump to Phase 5's design). Rejected: introduces
  cross-cutting Phase reordering and risks delaying Phase 2 by weeks.
  Conservative posture per `MEMORY.md → feedback_security_over_speed.md`
  is to land Phase 2 with the documented edge-VM pattern, then revisit
  in Phase 5 when the cluster is more mature.

## References

- [ARCHITECTURE.md § 6](../../ARCHITECTURE.md) — original Cloudflare
  Tunnel design
- [Runbook 03 § 5.1](../runbooks/03-phase2-cloudflared-tunnel.md) —
  the actual `config.yaml.tmpl` content this ADR justifies
- [`cloudflared/config.yaml.tmpl`](../../cloudflared/config.yaml.tmpl) —
  the deployed configuration
- ADR-0005 (table-only entry in [ARCHITECTURE.md § 12](../../ARCHITECTURE.md)) —
  Cloudflare Tunnel only, no port forwards. The parent decision this
  ADR elaborates: 0005 commits to "Tunnel as the only ingress path";
  0014 specifies *how* that Tunnel reaches the in-cluster ingress in
  Phase 2.
