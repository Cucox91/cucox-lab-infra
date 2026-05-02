# ADR-0015 — Open `cluster → dmz: tcp/2000` for Prometheus → cloudflared metrics scrape

> **Status:** Active (deviation, time-boxed)
> **Date:** 2026-05-01
> **Supersedes:** none
> **Superseded by:** none (yet — see "Closes when" below)
> **Owner:** Raziel

## Context

Phase 2 observability ([runbook 04](../runbooks/04-phase2-observability.md))
needs in-cluster Prometheus to scrape the operational metrics endpoint
exposed by `cloudflared` on `lab-edge01`. cloudflared exposes
`/metrics` in Prometheus exposition format on port `2000`.

Two structural facts make this scrape an explicit firewall question
rather than a routine ServiceMonitor:

1. **cloudflared is not a Kubernetes Service.** Per
   [ADR-0014](./0014-cloudflared-edge-vm-upstream-vip.md), cloudflared
   in Phase 2 runs as a systemd daemon on `lab-edge01` — a non-cluster
   VM in the **dmz** VLAN. There is no Endpoints / EndpointSlice for
   the Prometheus operator to discover, so a ServiceMonitor cannot
   apply. The clean path is a `prometheus.prometheusSpec.additionalScrapeConfigs`
   static target.
2. **The current inter-VLAN matrix denies the flow.**
   [ARCH § 3.3.1](../../ARCHITECTURE.md) currently allows
   `cluster → dmz: tcp/443 to ingress, tcp/7844 to cloudflared`. Port
   `2000` is not in the allow list, so default-deny applies. Without
   an explicit rule, the scrape times out.

cloudflared's `metrics:` config defaults to `127.0.0.1:2000` (loopback
only), set this way during runbook 03 § 5.1 with a deliberate
"runbook 04 will rebind" comment. Loopback-only was the conservative
default for the period when nothing was scraping; this ADR is the
trigger to widen it.

## Decision

**Add one allow rule** to the UCG-Max:

- **Cell:** `Lab-Cluster → Lab-DMZ` (Inter-VLAN)
- **Source — Network:** `Lab-Cluster` (`10.10.20.0/24`)
- **Destination — IP:** `10.10.30.21/32` (`lab-edge01`)
- **Protocol:** TCP
- **Port:** `2000`
- **Position:** Above any catch-all `Block All` in the cell, with a
  lower rule ID than the `Block All`. Verified in the rule-list view,
  not just the Zone Matrix display, per
  `MEMORY.md → unifi_zone_firewall_gotchas.md`.

**Rebind cloudflared's metrics endpoint** in
[`cloudflared/config.yaml.tmpl`](../../cloudflared/config.yaml.tmpl):

```yaml
# was:  metrics: 127.0.0.1:2000
# now:  metrics: 10.10.30.21:2000
```

The bind is to `10.10.30.21:2000` specifically (the dmz interface IP),
not `0.0.0.0:2000`. Functionally equivalent today on a single-NIC
VM, but if `lab-edge01` ever gains a second interface (a future
backup-ingest NIC, an out-of-band management bridge, etc.) the
`0.0.0.0` form would silently expose metrics on the new interface
too. Specific-IP binding makes the exposure surface explicit; the
firewall rule is the second layer.

**Return-traffic verification.** The existing
`Lab-DMZ → Lab-Cluster: Match State = Established, Related` rule
(added during runbook 03 § 3.2) covers the response half. UniFi's
state matcher is connection-state-based, not port-scoped, so any
existing flow's responses are permitted. Verified empirically in
runbook 04 § 1.3 with a temporary `nc` listener before assuming.

## Consequences

### Positive

- Unblocks Phase 2 observability with a single, narrowly-scoped
  firewall rule. No new infrastructure, no architectural shift.
- Source/dest are both load-bearing: `10.10.20.0/24` (cluster VLAN
  only) and `10.10.30.21/32` (lab-edge01 only), with `:2000`
  (cloudflared metrics specifically). Nothing else can use this rule.
- The cloudflared metrics endpoint stays unauthenticated — but the
  endpoint exposes only operational counters/gauges (active streams,
  registered connections, server locations) with no secrets. The
  attacker value of accessing it is low; the firewall + dmz isolation
  bound the access surface anyway.
- The flow respects the
  [`feedback_threat_priority_home_first.md`](../../) priority order:
  it stays inside lab VLANs (cluster + dmz), does not touch Default
  LAN / NAS / cameras / work computer, and adds zero public surface.
- `dmz → External` egress is unchanged. cloudflared metrics on `:2000`
  are never reachable from the public internet, only from cluster
  VLAN.

### Negative

- ARCH § 3.3.1's matrix gains an entry. The `cluster → dmz` row is no
  longer just "tunnel data path" — it now also includes a control-
  plane observability flow. Future readers must understand both
  reasons for the cell to be permissive.
- A compromised in-cluster Prometheus could now reach `lab-edge01:2000`
  on top of the existing reachable surface. cloudflared's metrics
  endpoint is read-only HTTP exposition — no command channel — so the
  blast radius is bounded to "attacker can read tunnel operational
  metrics they probably already have other paths to infer". Not zero,
  but materially smaller than the existing `cluster → ingress` and
  `cluster → cloudflared:7844` flows already in the same cell.
- The metrics endpoint stays unauthenticated. Adding bearer-token auth
  to cloudflared's `/metrics` requires Cloudflare's Tunnel sidecar
  proxy and is materially more setup. The firewall narrowing is the
  defense.

### Mitigations and second-order considerations

- **Source-IP narrowing is at the SNAT level, not the pod level.**
  Cilium SNATs cluster pod traffic to the egress node IP before it
  hits the UCG-Max, so the firewall sees `10.10.20.21..32` (node
  IPs), not pod IPs. This means *any* compromised cluster pod, not
  just Prometheus, can reach `:2000` through this rule. Acceptable
  given the read-only exposition, but worth noting.
- **No alerting yet.** Per ARCH § 7.2, Alertmanager is deferred to
  Phase 4. So a degraded cloudflared metrics endpoint won't page
  anyone — a human operator must look at the Grafana dashboard.
  Acceptable for Phase 2; revisit when Alertmanager lands.

## Closes when

This deviation closes when the **Phase 5 plan** from ARCH § 6.1 is
executed: `cloudflared` moves into the cluster as a Deployment with
replicas across worker nodes for HA (the same plan that
[ADR-0014](./0014-cloudflared-edge-vm-upstream-vip.md) closes on).

At that point:

- `cloudflared` becomes a normal in-cluster workload. Its `/metrics`
  endpoint is scraped via a normal `PodMonitor` or `ServiceMonitor`,
  no `additionalScrapeConfigs` needed.
- The `cluster → dmz: tcp/2000 to 10.10.30.21` rule on the UCG-Max
  becomes obsolete and must be removed in the same PR that lands the
  in-cluster Deployment. Leaving stale allow rules behind is exactly
  the kind of drift the security-conservative posture argues against.
- `cloudflared/config.yaml.tmpl`'s `metrics:` line either reverts to
  `127.0.0.1:2000` (if cloudflared still has a copy on `lab-edge01`
  for redundancy) or disappears entirely (if `lab-edge01` is retired).

A successor ADR will record the migration and supersede this one.

## Alternatives considered

- **Bind cloudflared metrics to `0.0.0.0:2000`** instead of
  `10.10.30.21:2000`. Rejected: silently expands exposure if
  `lab-edge01` ever gains a second NIC. The defense is one extra
  config-file character ("0" → "10.10.30.21") so the trade-off is
  trivially in favor of the specific bind.
- **Run a sidecar reverse proxy on `lab-edge01`** (nginx, caddy) that
  authenticates the scrape with a bearer token before forwarding to
  cloudflared's loopback `:2000`. Rejected as over-engineering for
  Phase 2: adds a new daemon, a new auth secret, a new place for the
  config to drift. The firewall + dmz isolation deliver
  near-equivalent protection with materially less moving complexity.
  Revisit if Phase 4 brings stronger requirements (e.g., per-pod
  egress identity).
- **Move cloudflared in-cluster now** (jump straight to the Phase 5
  design and skip the Phase 2 edge-VM pattern). Rejected for the same
  reasons as ADR-0014's parallel alternative: introduces cross-cutting
  Phase reordering and risks delaying Phase 2 by weeks. Conservative
  posture per `MEMORY.md → feedback_security_over_speed.md` is to land
  Phase 2 with the documented edge-VM pattern, then revisit in
  Phase 5.
- **Skip cloudflared scraping entirely** and rely on Cloudflare's
  dashboard for tunnel health. Rejected: dashboard tells you "tunnel
  HEALTHY" but not the operational details (active streams, request
  latency from cloudflared's perspective, server-location load) that
  matter when debugging. The whole point of Phase 2 observability is
  in-house metrics, not vendor dashboards.

## References

- [ARCHITECTURE.md § 3.3.1](../../ARCHITECTURE.md) — inter-VLAN matrix
  (the `cluster → dmz` row gets `tcp/2000` added)
- [ARCHITECTURE.md § 7.1](../../ARCHITECTURE.md) — Day-1 observability
  stack design
- [Runbook 04 § 1](../runbooks/04-phase2-observability.md) — the
  firewall preflight + ADR write-then-rule sequence
- [Runbook 04 § 6](../runbooks/04-phase2-observability.md) — the
  cloudflared metrics rebind + Prometheus `additionalScrapeConfigs`
- [Runbook 03 § 5.1](../runbooks/03-phase2-cloudflared-tunnel.md) —
  the original `metrics: 127.0.0.1:2000` config this ADR rebinds
- [`cloudflared/config.yaml.tmpl`](../../cloudflared/config.yaml.tmpl) —
  the deployed configuration
- [ADR-0014](./0014-cloudflared-edge-vm-upstream-vip.md) — the parent
  Phase 2 cloudflared deviation, which this ADR layers a metrics
  scrape onto
- `MEMORY.md → feedback_threat_priority_home_first.md` — the
  priority order this ADR's allow rule respects
- `MEMORY.md → unifi_zone_firewall_gotchas.md` — the rule-ordering
  invariant the implementation must preserve
