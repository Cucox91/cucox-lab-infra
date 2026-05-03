# Runbook 04a — Hardware Temperature & Disk-Health Monitoring

> **Goal:** Land continuous monitoring of the *physical* health of the
> Ryzen — CPU temp (via `k10temp`), NVMe temps + SMART attributes (via
> `smartctl`), thermal-throttling events (via the kernel's MSR counters)
> — into the Prometheus stack from runbook 04, with thresholds wired
> for the Phase 4 Alertmanager rollout. After this runbook the operator
> can answer "is the lab cooking itself?" from a Grafana dashboard
> instead of by walking to the rack.
>
> **Estimated time:** 90 minutes. Most of it is `sensors-detect` and
> the first stress-test verification. Helm + Prometheus changes are
> small.
>
> **When to run:** After [`04-phase2-observability.md`](./04-phase2-observability.md)
> (kube-prometheus-stack is up and Grafana is reachable). Before any
> Phase 3 production-shaped workload lands — you want the thermal
> baseline established under *empty-cluster* load before app load is
> added on top.
>
> **Operator:** Raziel, Mac Air on `CucoxLab-Mgmt` (VLAN 10), with
> root SSH to `lab-prox01` (`10.10.10.10`).

---

## The mental model: where physical metrics actually live

This is the single most important conceptual point in the runbook, so
it's first.

| Layer | Has thermal sensors? | Why / why not |
|---|---|---|
| **The Ryzen (`lab-prox01`)** — bare metal | **Yes.** `k10temp` exposes CPU package + Tctl. Motherboard sensors expose VRM/chipset/board temp. NVMe controllers expose composite + sensor 1/2 temps via the NVMe-CLI / SMART interface. | This is the only host in the lab where physical sensors are real. |
| **k3s VMs** (`lab-cp01..03`, `lab-wk01..02`) | **No.** QEMU does not virtualize hwmon devices by default. `sensors` inside a guest returns "No sensors found." | The hypervisor abstracts the silicon away. Guests see vCPU load, not silicon temperature. |
| **`lab-edge01`** (dmz VM) | **No.** Same reason. | Same as above. |
| **Pi 5 / Pi 4** (Phase 5) | **Yes** (different interface). Read via `vcgencmd measure_temp` or `/sys/class/thermal/thermal_zone0/temp`. | Different metric path; different exporter (`rpi_exporter`). Deferred to a Phase 5 follow-up. |

**Implication:** there is exactly *one* host whose temperature matters
for "is the lab cooking" — the Ryzen. Adding temp scraping to the
in-cluster `node_exporter` DaemonSet (which runs in the VMs) accomplishes
nothing physical. The exporter we care about runs on `lab-prox01` as a
systemd service, **outside the cluster**, scraped by Prometheus the same
way cloudflared on `lab-edge01` is scraped (per
[ADR-0015](../decisions/0015-cluster-dmz-2000-prometheus-cloudflared.md)
+ runbook 04 § 6).

The corollary is that *guest* CPU/memory/disk-I/O metrics from the in-
cluster DaemonSet are still useful — they tell you what each VM is
*doing*. They just don't tell you what it's *suffering*. Both are
needed; both are scraped; they answer different questions.

---

## What this runbook implements

| ARCHITECTURE.md ref | Implemented here |
|---|---|
| § 7.1 — Day-1 stack | Adds the **host-side** `node_exporter` as a static Prometheus scrape target (`10.10.10.10:9100`) alongside the in-cluster DaemonSet from runbook 04. Adds an additional textfile-collector exporter for SMART data. |
| § 2.1 — Phase 1 hardware | Defines per-component thermal thresholds tied to the actual silicon: 5950X package, two PCIe Gen 4 NVMes, the AM4 board's VRMs. |
| § 7.2 — Future additions | Pre-writes the temperature alert rules so they're ready to wire into Alertmanager when Phase 4 lands. Loaded into Prometheus today as `record:` rules and as `alert:` rules with no notification path. |
| § 3.3 — Inter-VLAN | One new allow rule on the UCG-Max: `cluster (10.10.20.0/24) → mgmt (10.10.10.10):tcp/9100`. Documented as **ADR-0017** (stub created in Step 1). |

What this runbook does **not** do:

- Wire Alertmanager / paging — deferred to Phase 4 per ARCH § 7.2.
- Cover Pi-side thermals (`rpi_exporter`) — deferred to Phase 5.
- Add fan-curve control / IPMI fan management — the Ryzen's BIOS handles
  fan curves; we observe, we do not actively cool.
- Cover ZFS-level disk-health checks (`zpool status`, scrub schedule).
  That belongs in a future PBS / storage runbook; thermal + SMART here
  is a *complementary* but distinct view.

---

## Prerequisites

- **Runbook 04 complete.** kube-prometheus-stack running, Prometheus
  scraping the in-cluster node-exporter DaemonSet, Grafana reachable at
  `https://grafana.lab.cucox.local/`. The pattern this runbook copies
  is the cloudflared `additionalScrapeConfigs` pattern from
  runbook 04 § 6 + ADR-0015.

  ```sh
  kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus
  # Expect: prometheus-kube-prometheus-prometheus-0 Running 2/2.
  ```

- **`MEMORY.md → psa_node_exporter_baseline_blocks`** is already applied
  for the in-cluster DaemonSet. This runbook adds an *additional* host-
  side exporter that does **not** run in any namespace, so PSA does not
  apply to it. No new PSA configuration needed.

- **A way to put the CPU under sustained load** for the Step 8
  verification. Either `stress-ng` (`apt install stress-ng` on the
  Proxmox host) or `sysbench`. Don't skip the verification — an alert
  rule that *looks* correct in YAML but never fires under real load is
  worse than no alert at all.

- **30 minutes of "no other work happening"** during Step 8 — the load
  test will pin every core for ~5 minutes and any in-flight VM I/O will
  feel it.

---

## Step 0 — Decisions to lock

| Variable | Value | Source |
|---|---|---|
| Host-side node-exporter version | latest stable from Prometheus releases (currently 1.8.x) | upstream |
| Host-side node-exporter port | `9100` | exporter default |
| Host-side node-exporter bind | `10.10.10.10:9100` (mgmt VLAN interface only, not `0.0.0.0`) | defense-in-depth, same pattern as cloudflared in ADR-0015 |
| smartctl_exporter version | latest stable (currently 0.13.x) | upstream |
| smartctl_exporter port | `9633` | exporter default |
| Scrape interval | `30s` (matches in-cluster default) | runbook 04 |
| New firewall allow | `cluster (10.10.20.0/24) → mgmt (10.10.10.10):tcp/9100, tcp/9633` | new (this runbook); ADR-0017 |
| CPU package warn / crit | **75 °C / 85 °C** (5950X Tjmax = 90 °C; warn 15 °C below, crit 5 °C below) | AMD spec sheet + safety margin |
| CPU sustained-load warn duration | `5m` (transient spikes to 80 °C during compile bursts are normal; 5 min sustained is not) | observed under stress-ng |
| NVMe warn / crit | **65 °C / 75 °C** (most consumer NVMes throttle 70–80 °C; warn well before throttle) | drive datasheets |
| NVMe SMART critical attrs | `media_errors > 0`, `unsafe_shutdowns` delta in 1h > 0, `wear_leveling_count` < 90 | drive vendor guidance |
| ZFS scrub frequency (referenced, not configured here) | monthly, alert if last scrub > 35 days | future storage runbook |

---

## Step 1 — Firewall preflight + new `cluster → mgmt:9100/9633` allow

Same flow shape as ADR-0015's `cluster → dmz:2000` rule, against a
different destination cell.

### 1.0 — Pre-write ADR-0017 stub

ARCH § 3.3.1 currently allows `cluster → mgmt: <none>` (cluster cannot
reach mgmt by default — exactly what `feedback_threat_priority_home_first.md`
wants). Adding two scrape ports is a deviation worth recording before
the rule is added, not after.

Create `docs/decisions/0017-cluster-mgmt-9100-9633-host-metrics.md`
following the ADR-0015 template:

- **Status:** Active (deviation, time-boxed).
- **Decision:** Allow `Lab-Cluster (10.10.20.0/24) → Lab-Mgmt
  (10.10.10.10/32) tcp/9100, tcp/9633`. Above any catch-all Block in
  the cell.
- **Closes when:** A Phase 4 redesign moves either (a) host metrics into
  the cluster via a privileged DaemonSet that hostmounts `/sys` and
  `/dev`, or (b) a sidecar on the host that pushes to a Pushgateway in
  the cluster. The first option is the cleaner endgame; this runbook
  takes the conservative path.
- **Alternatives considered:** Push-mode (host pushes to Pushgateway in
  cluster — rejected, adds a stateful component the lab doesn't need
  yet), expose host node-exporter publicly (rejected, exposes drive
  serials and BIOS strings), Prometheus Federation from a host-local
  Prometheus (rejected, two Prometheis is more moving parts than one
  scrape rule).

Commit the ADR. Then add the rule.

### 1.1 — Add the allow rule on the UCG-Max

In the UniFi Network app:

1. **Settings → Security → Traffic Rules** (or Firewall Rules,
   depending on UniFi version) → **+ Create Rule** in the
   `Lab-Cluster → Lab-Mgmt` cell.
2. **Action:** Allow.
3. **Source — Network:** `Lab-Cluster` (`10.10.20.0/24`).
4. **Destination — IP:** `10.10.10.10/32`.
5. **Protocol:** TCP. **Ports:** `9100,9633`.
6. **Position:** Above any catch-all Block in this cell. Verify in the
   rule-list view, not the Zone Matrix display
   (`MEMORY.md → unifi_zone_firewall_gotchas.md`).

### 1.2 — Verify the rule before exporters exist

```sh
# From lab-wk01 (any cluster-VLAN host):
ssh ubuntu@10.10.20.31 "nc -z -v -w 3 10.10.10.10 9100; nc -z -v -w 3 10.10.10.10 9633"
# Expect: connection refused on both (ports closed because exporters
# aren't running yet — that's fine, it confirms the firewall *itself*
# isn't dropping the SYN).
```

If you see "no route to host" or "operation timed out" the firewall
rule isn't applied — fix before continuing. "Connection refused"
means the SYN reached the host and the host kernel sent RST because
nothing listens — which is exactly what we want at this point.

---

## Step 2 — Install `lm-sensors` and confirm the Ryzen's `k10temp`

```sh
ssh root@10.10.10.10
apt-get update
apt-get install -y lm-sensors
```

The 5950X's CPU temp sensor is `k10temp` (built into the kernel since
~3.x). The motherboard sensors usually need an additional `nct6775` or
similar I²C/SMBus chip. `sensors-detect` finds them.

```sh
sensors-detect --auto
# --auto accepts every safe default. The probes it skips are I²C scans
# of unknown SMBus addresses on consumer boards — declining them is the
# right call. If you want to be more aggressive, run without --auto and
# answer "yes" only to probes labeled "safe."
```

After it finishes, it writes any required modules to
`/etc/modules-load.d/sensors-detect.conf`. Reboot or load them now:

```sh
systemctl restart kmod-static-nodes systemd-modules-load
modprobe k10temp
[ -f /etc/modules-load.d/sensors-detect.conf ] && \
  while read m; do [ -n "$m" ] && [ "${m:0:1}" != "#" ] && modprobe "$m"; done \
    < /etc/modules-load.d/sensors-detect.conf

sensors
```

Expected output structure (values illustrative):

```
k10temp-pci-00c3
Adapter: PCI adapter
Tctl:         +42.2°C
Tccd1:        +39.5°C
Tccd2:        +38.0°C

nct6798-isa-0290
Adapter: ISA adapter
SYSTIN:       +35.0°C
CPUTIN:       +43.0°C
AUXTIN0:      +30.0°C
in0:          +1.41 V
in1:          +1.05 V
fan1:         1234 RPM (CPU fan)
fan2:         800 RPM (chassis)
```

If `sensors` outputs nothing useful, troubleshoot before continuing —
no exporter can publish data the kernel doesn't know about.

`Tctl` is AMD's "control temperature" — it's the value the BIOS uses for
fan curves and is offset from "real" silicon temperature on some
generations. For the 5950X, Tctl ≈ silicon temperature with no
significant offset. Use Tctl as the alerting metric.

---

## Step 3 — Install `node_exporter` on the Proxmox host (not in cluster)

The in-cluster DaemonSet from runbook 04 already covers VM-side metrics.
This is the *additional* exporter on the bare-metal host that publishes
hwmon data. It runs as a systemd service, not in k8s.

### 3.1 Create a dedicated service user

```sh
ssh root@10.10.10.10
useradd --system --no-create-home --shell /usr/sbin/nologin --user-group node_exporter
```

### 3.2 Install the binary

```sh
NODE_EXPORTER_VERSION=1.8.2   # bump to current stable; check https://github.com/prometheus/node_exporter/releases
cd /tmp
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  | tar -xzf - --strip-components=1 -C /tmp \
        "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter"
install -o node_exporter -g node_exporter -m 0755 /tmp/node_exporter /usr/local/bin/node_exporter

# Verify checksum against the upstream SHA256SUMS file before installing
# in any non-throwaway environment. Skipping this check has bitten
# everyone exactly once.
```

### 3.3 Create the textfile-collector directory

For SMART data (Step 4) and ZFS data (future), the host exposes them via
`.prom` files written into a dedicated directory that node-exporter
serves alongside its built-in collectors.

```sh
install -d -o node_exporter -g node_exporter -m 0755 /var/lib/node_exporter/textfile_collector
```

### 3.4 systemd unit, bound to the mgmt interface

```sh
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus node_exporter (host metrics for lab-prox01)
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=10.10.10.10:9100 \
  --collector.hwmon \
  --collector.thermal_zone \
  --collector.systemd \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector \
  --no-collector.wifi \
  --no-collector.bcache \
  --no-collector.infiniband
Restart=on-failure
RestartSec=5s

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=false   # need access to hwmon
ReadWritePaths=/var/lib/node_exporter
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
systemctl status node_exporter --no-pager
```

`--web.listen-address=10.10.10.10:9100` — bound to the mgmt interface
specifically, **not** `0.0.0.0:9100`. If the Ryzen ever gains a second
NIC (a backup-ingest interface, an out-of-band management bridge, the
Phase 5 ARM bridge), the metrics endpoint won't silently follow. The
firewall rule from Step 1 is the second layer; the bind is the first.

### 3.5 Smoke-test from the cluster VLAN

```sh
ssh ubuntu@10.10.20.31 "curl -sf http://10.10.10.10:9100/metrics | grep -E '^node_hwmon_temp_celsius' | head"
# Expect: a few lines like:
#   node_hwmon_temp_celsius{chip="pci0000:00_0000:00:18_3",sensor="temp1"} 42.25
```

If you don't see any `node_hwmon_temp_celsius` lines, `sensors` and
`node_exporter` are looking at different sets of sensors — `--collector.hwmon`
walks `/sys/class/hwmon`, which is what `lm-sensors` populates after
Step 2. Confirm `ls /sys/class/hwmon` has entries; if not, return to
Step 2.

---

## Step 4 — NVMe + SATA SMART via `smartctl_exporter`

`smartctl_exporter` (the Prometheus community one — github.com/prometheus-community/smartctl_exporter)
runs as a privileged service that periodically `smartctl -a /dev/nvmeN`
each disk and exposes the parsed result on `/metrics`.

### 4.1 Install `smartmontools` and the exporter binary

```sh
apt-get install -y smartmontools

SMARTCTL_EXPORTER_VERSION=0.13.0   # check upstream releases
cd /tmp
curl -fsSL "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-amd64.tar.gz" \
  | tar -xzf - --strip-components=1 -C /tmp \
        "smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-amd64/smartctl_exporter"
install -o root -g root -m 0755 /tmp/smartctl_exporter /usr/local/bin/smartctl_exporter

# Sanity: enumerate disks the exporter will scan.
smartctl --scan
# Expect both NVMes listed: /dev/nvme0 and /dev/nvme1 (or by-id paths).
```

### 4.2 systemd unit (runs as root — `smartctl` needs raw device access)

```sh
cat > /etc/systemd/system/smartctl_exporter.service <<'EOF'
[Unit]
Description=Prometheus smartctl_exporter (NVMe + SATA SMART metrics)
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/smartctl_exporter \
  --web.listen-address=10.10.10.10:9633 \
  --smartctl.interval=300s \
  --smartctl.rescan=24h
Restart=on-failure
RestartSec=10s

# Minimal hardening — root is required for /dev/nvme* but limit beyond
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now smartctl_exporter
systemctl status smartctl_exporter --no-pager
```

`--smartctl.interval=300s` runs `smartctl -a` every 5 minutes per disk.
NVMe controllers don't love being polled too aggressively (some
controllers add latency on a SMART read); 5 min is a comfortable
default.

### 4.3 Smoke-test

```sh
ssh ubuntu@10.10.20.31 "curl -sf http://10.10.10.10:9633/metrics | grep -E '^smartctl_device_temperature' | head"
# Expect lines per disk and sensor:
#   smartctl_device_temperature{device="nvme0",temperature_type="current"} 38
#   smartctl_device_temperature{device="nvme0",temperature_type="drive_trip"} 81
```

---

## Step 5 — Wire both exporters into Prometheus

Same `additionalScrapeConfigs` pattern as runbook 04 § 6 (cloudflared)
and the same SOPS-sealed Secret approach.

### 5.1 Edit the kube-prometheus-stack values overlay

Open `k8s/kube-prometheus-stack/values.yaml` (the file runbook 04
created). Add to the existing `additionalScrapeConfigs` block:

```yaml
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
      # … existing cloudflared scrape from runbook 04 § 6 stays here …

      - job_name: 'lab-prox01-node'
        scrape_interval: 30s
        static_configs:
          - targets: ['10.10.10.10:9100']
            labels:
              instance: 'lab-prox01'
              role: 'hypervisor'

      - job_name: 'lab-prox01-smart'
        scrape_interval: 60s        # smartctl_exporter caches; 60s is plenty
        static_configs:
          - targets: ['10.10.10.10:9633']
            labels:
              instance: 'lab-prox01'
              role: 'hypervisor'
```

### 5.2 Apply via the same Helm upgrade pattern from runbook 04

```sh
cd /Users/cucox91/Documents/Claude/Projects/Cucox\ Lab/cucox-lab-infra
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 84.5.0 \
  -f k8s/kube-prometheus-stack/values.yaml \
  --set-file grafana.adminPassword=<(sops -d ansible/group_vars/monitoring/grafana.enc.yaml | yq -r .grafana_admin_password)
```

### 5.3 Verify both targets are UP in Prometheus

```sh
# Port-forward Prometheus from the Mac Air:
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
open http://localhost:9090/targets
# Expect: lab-prox01-node (1/1 up), lab-prox01-smart (1/1 up).

# Or query directly:
curl -s 'http://localhost:9090/api/v1/query?query=up{instance="lab-prox01"}' | jq '.data.result'
# Expect two results both with value [<time>, "1"].
```

If either target is **DOWN**, walk the chain: cluster pod → SNAT
node IP → UCG-Max rule (Step 1.2) → exporter listening (Step 3.5 /
4.3). The cluster→mgmt direction is new for this runbook so the rule
is the most likely culprit.

---

## Step 6 — Recording + alert rules

Add a `PrometheusRule` CR. These define both `record:` rules
(efficiency: precompute the query for dashboards) and `alert:` rules
(notification: fire when a condition is met for a duration). The alerts
sit dormant until Phase 4 wires Alertmanager to an actual notifier; in
the meantime they show up in Prometheus' Alerts tab as **PENDING** /
**FIRING** so a human can spot-check them.

Create `k8s/kube-prometheus-stack/rules/hardware-thermal.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hardware-thermal
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # the chart's selector label — required
spec:
  groups:
    - name: hardware-thermal.recording
      interval: 30s
      rules:
        # Tctl is the AMD control temp; on the 5950X it's the practical
        # silicon temp. Average across CCDs to get a single per-host metric.
        - record: lab:cpu_temp_celsius
          expr: |
            avg by (instance) (
              node_hwmon_temp_celsius{chip=~".*k10temp.*"}
            )

        - record: lab:nvme_temp_celsius
          expr: |
            max by (instance, device) (
              smartctl_device_temperature{temperature_type="current"}
            )

    - name: hardware-thermal.alerts
      rules:
        - alert: CpuTempWarn
          expr: lab:cpu_temp_celsius > 75
          for: 5m
          labels:
            severity: warning
            component: hypervisor
          annotations:
            summary: "CPU temp on {{ $labels.instance }} sustained > 75 °C"
            description: |
              5950X Tctl average has been above 75 °C for 5 minutes
              ({{ $value }} °C). Throttle threshold is 95 °C; this is
              an early-warning to investigate cooling (dust, fan curve,
              ambient temperature) before throttling starts.
            runbook: "docs/runbooks/04a-hardware-temperature-disk-health.md#step-9--restoration-recipes"

        - alert: CpuTempCritical
          expr: lab:cpu_temp_celsius > 85
          for: 1m
          labels:
            severity: critical
            component: hypervisor
          annotations:
            summary: "CPU temp on {{ $labels.instance }} above 85 °C"
            description: |
              5950X Tctl above 85 °C — within 10 °C of throttle
              ({{ $value }} °C). Investigate immediately; consider
              cordoning lab-wk01/lab-wk02 to drop load if the cause
              is workload-driven.

        - alert: NvmeTempWarn
          expr: lab:nvme_temp_celsius > 65
          for: 5m
          labels:
            severity: warning
            component: storage
          annotations:
            summary: "NVMe {{ $labels.device }} sustained > 65 °C"
            description: |
              NVMe {{ $labels.device }} has been above 65 °C for 5
              minutes ({{ $value }} °C). Most consumer NVMes thermal-
              throttle 70–80 °C. Check airflow and consider a heatsink
              if not already fitted.

        - alert: NvmeTempCritical
          expr: lab:nvme_temp_celsius > 75
          for: 1m
          labels:
            severity: critical
            component: storage
          annotations:
            summary: "NVMe {{ $labels.device }} above 75 °C"
            description: |
              NVMe {{ $labels.device }} above 75 °C — likely throttling
              ({{ $value }} °C). Reduce I/O load (pause backups, pause
              benchmark workloads) and investigate cooling.

        - alert: NvmeMediaErrors
          expr: increase(smartctl_device_media_errors[1h]) > 0
          for: 5m
          labels:
            severity: critical
            component: storage
          annotations:
            summary: "NVMe {{ $labels.device }} reported new media errors"
            description: |
              SMART media error counter incremented in the last hour.
              Even one is significant on consumer NVMe — start planning
              a replacement and verify the Layer-2 baseline stream from
              runbook 00b is intact.

        - alert: NvmeWearHigh
          expr: smartctl_device_percentage_used > 80
          for: 1h
          labels:
            severity: warning
            component: storage
          annotations:
            summary: "NVMe {{ $labels.device }} wear > 80 %"
            description: |
              SMART percentage_used is above 80. Plan replacement
              within the next 6 months; this drive will start showing
              throughput degradation soon.

        - alert: HostThermalThrottle
          expr: increase(node_thermal_zone_temp[5m]) > 0 and node_thermal_zone_temp > 90
          for: 1m
          labels:
            severity: critical
            component: hypervisor
          annotations:
            summary: "Thermal-zone events on {{ $labels.instance }}"
            description: |
              Kernel reported thermal events; CPU is throttling. This
              is the actual "the lab is cooking" alert — anything above
              this is the silicon protecting itself by cutting clocks.
```

Apply it:

```sh
kubectl apply -f k8s/kube-prometheus-stack/rules/hardware-thermal.yaml

# Verify Prometheus picked it up:
kubectl -n monitoring exec -it prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  promtool query instant http://localhost:9090 'ALERTS{alertname=~"CpuTemp.*|Nvme.*"}' | head
# Expect: a list of alert states (mostly "inactive" if temps are nominal).
```

The chart's Prometheus instance auto-loads any `PrometheusRule` CR with
the matching `release:` label — no Helm upgrade needed for rule-only
changes.

---

## Step 7 — Grafana dashboard

Two viable paths, pick one:

**Path A (recommended for Phase 2): seed an existing community
dashboard.** Grafana dashboard ID **1860** (Node Exporter Full) covers
the node-exporter metrics, including hwmon. Import it via the Grafana UI
→ Dashboards → New → Import → ID 1860 → datasource: Prometheus. It will
"just work" against the host scrape job.

For SMART, dashboard ID **20204** (smartctl_exporter) is the upstream
choice. Same import flow.

**Path B: bake into the stack as a Grafana ConfigMap.** Drop the JSON
into `k8s/kube-prometheus-stack/dashboards/hardware-thermal.json` and
reference it from `values.yaml` under
`grafana.dashboardsConfigMaps`. Survives Grafana pod restarts; survives
chart upgrades. The right answer eventually; Path A is fine for getting
a view today.

Either way, after import, browse to **Dashboards → Node Exporter Full**
and confirm the Temperatures panel is populated. The first scrape after
exporter install can take 60 s to land — a "no data" panel for a minute
is not a failure.

---

## Step 8 — Verification: stress the CPU and watch it heat up

The point of a thermal monitoring system is to *react* to a real thermal
event. Without an actual stress test you have a YAML file that
*claims* to monitor temperatures.

### 8.1 Pre-flight: capture baseline temps

```sh
ssh root@10.10.10.10
sensors | grep -E 'Tctl|Tccd1|Tccd2'
# Note the idle Tctl. Typical 5950X idle on stock cooler in a 22 °C
# room: 35–45 °C.
```

In Grafana, open **lab:cpu_temp_celsius** in Explore → see a flat line.

### 8.2 Run a 5-minute stress

```sh
apt-get install -y stress-ng   # if not already
stress-ng --cpu 32 --cpu-method matrixprod --timeout 5m --metrics-brief
```

`--cpu 32` saturates all 32 logical cores; `matrixprod` is a heat-
oriented method (BLAS-style FP). On a 5950X with stock cooling in a
typical room, expect Tctl to ramp to 75–85 °C within 60–90 seconds.

### 8.3 Watch the alert trip

```sh
# In a second terminal on the Mac Air, port-forward Prometheus and watch:
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
watch -n 5 'curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode "query=lab:cpu_temp_celsius" \
  | jq ".data.result"'
```

Expected sequence over 5 minutes:

1. `lab:cpu_temp_celsius` climbs from idle to 75–85 °C.
2. After it stays above 75 °C for 5 min (the `for:` window), `CpuTempWarn`
   transitions PENDING → FIRING.
3. After it crosses 85 °C for 1 min, `CpuTempCritical` fires.

Open the Prometheus UI's **Alerts** tab to confirm visually. If neither
fires despite the temperature reading high enough, the rule's label
selectors (`chip=~".*k10temp.*"`) don't match what the exporter
publishes — diff `node_hwmon_temp_celsius` labels in Prometheus against
the regex.

If the temperature *doesn't* climb to 75 °C even under saturated load,
either (a) cooling is excellent (lucky you), or (b) the exporter is
publishing a different sensor than the one heating up — re-check
`sensors` output and confirm `k10temp` is the one with the warm
readings.

### 8.4 Stop the stress and confirm cool-down

```sh
# stress-ng stops on its own at the timeout; if you ctrl-C'd:
pkill stress-ng
```

In the dashboard, watch Tctl drop back toward idle within ~60 seconds.
Alerts should clear (FIRING → INACTIVE) after the temperature drops
below threshold *and* the rule's resolution check fires (~30 s).

### 8.5 Document the baseline

Append to your operator notebook (or `docs/log/`):

- Date + ambient temperature.
- Idle Tctl (e.g., 38 °C).
- Stress-ng matrixprod 5-min steady-state Tctl (e.g., 82 °C).
- NVMe steady-state under the same load (e.g., 48 °C — likely cooler
  than CPU since they're not under I/O during a CPU stress).
- Alert that fired and after how long.

This is your reference for "is the lab hotter than it was last month?"
— the sort of question a slow trend (dust accumulation, declining fan
RPM) makes hard to answer without a baseline.

---

## Step 9 — Restoration recipes

### "CpuTempWarn fires under what *should* be a low workload"

- Check workload first: `kubectl top nodes`, `kubectl top pods -A`.
  A runaway pod is the most common cause.
- If load is genuinely low: dust. Ryzen tower coolers accumulate dust
  on intake fins faster than chassis intake filters. Power off, blow
  out with compressed air, restart. Alert should clear within an hour
  as the heatsink re-equilibrates.
- Ambient: a 30 °C room day adds 5–10 °C to steady-state Tctl. If your
  baseline was set in winter and it's now summer, the threshold may
  need a seasonal bump (or, the *correct* fix, more airflow).

### "NvmeTempWarn fires repeatedly during k3s image pulls"

NVMe writes during a coordinated image pull (5 nodes pulling the same
2 GB image into local-path PVs on `lab-wk01`) can heat the drive 10 °C
in 30 s. If this happens, the right answer is usually a heatsink — most
consumer M.2 NVMes ship without one and the thermal headroom is real.
A $5 aluminum heatsink + thermal pad drops sustained-write temps by
15–20 °C.

Adding a Phase 4 registry mirror (Harbor in-cluster) eliminates the
coordinated-pull thundering herd entirely; that's the structural
fix.

### "NvmeMediaErrors fires"

This is the alert you most hope never fires. Sequence:

1. Don't panic; one error doesn't mean imminent death — but it does
   mean the disk is no longer "as good as new."
2. Confirm the Layer-2 baseline stream from
   [runbook 00b](./00b-proxmox-baseline-snapshot.md) is intact:
   `zstd -dc /mnt/baseline/.../rpool-….zfs.zst | zstreamdump | tail`.
3. `zpool status -x` — ZFS will surface checksum errors if data on the
   affected drive is corrupted. If `tank` is a single-disk pool (per
   ADR-0011's Phase 1 single-pool deviation), there is no redundancy —
   start the replacement plan now.
4. Replace the drive within days, not weeks. RMA if under warranty.

### "HostThermalThrottle fires"

This means the kernel actually throttled the CPU — the silicon
protecting itself. The lab is *currently* slowed down.

- Immediate: cordon `lab-wk01` and `lab-wk02` (`kubectl cordon`) to
  stop new pods from landing. Existing pods continue but no new load
  arrives.
- Investigate cooling. Throttling on a 5950X typically requires either
  a failed fan, a clogged heatsink, or thermal-paste failure (the
  latter rare unless the cooler has been removed and reinstalled).
- After fixing, uncordon and watch the next stress test confirm normal
  steady-state.

### "Both exporters show DOWN in Prometheus"

Walk the chain in this order, since each is more likely than the
next:

1. Exporter binary running? `systemctl is-active node_exporter
   smartctl_exporter` on the host.
2. Listening on the right interface? `ss -ltn | grep -E ':9100|:9633'`
   — should show `10.10.10.10:9100` and `10.10.10.10:9633`, **not**
   `0.0.0.0:*`.
3. Firewall rule applied? Step 1.2 reachability test.
4. Prometheus scrape config has the right address?
   `kubectl -n monitoring get prometheus -o yaml | grep -A3 lab-prox01`.
5. Cilium SNAT making the source IP look unexpected? `kubectl exec`
   into a Prometheus pod and `curl http://10.10.10.10:9100/metrics`
   from there to bypass Prometheus's scrape entirely.

---

## What's done

- The Ryzen exposes hwmon temperatures via `lm-sensors` and `k10temp`.
- A host-side `node_exporter` publishes them on `10.10.10.10:9100`.
- A `smartctl_exporter` publishes NVMe SMART (including temps and wear)
  on `10.10.10.10:9633`.
- One new firewall allow on the UCG-Max (`cluster → mgmt:9100,9633`)
  with ADR-0017 documenting the deviation.
- Prometheus scrapes both targets via `additionalScrapeConfigs`.
- Recording + alert rules (CPU 75/85 °C, NVMe 65/75 °C, media errors,
  wear, kernel throttle) are loaded.
- A real stress test verified the alerts fire end-to-end.
- A Grafana dashboard surfaces the same data for at-a-glance review.
- Baseline temperatures are recorded for trend comparison.

## What's next

- **Phase 4:** wire the existing alerts to Alertmanager. Routes:
  `severity=critical` → email + ntfy push to phone; `severity=warning`
  → email only. Alertmanager itself is the Phase 4 work; the *rules*
  are already in place from this runbook.
- **Phase 4:** add a `zpool_exporter` (or use the textfile collector +
  a 5-minute cron writing `zpool status` to a `.prom` file) for ZFS-
  level disk health: `zpool_status` enum, last-scrub age, error counts
  per vdev. Complements the SMART view with the *filesystem*'s view of
  the same disks.
- **Phase 5:** add `rpi_exporter` to each Pi node so their thermals
  flow into the same Prometheus + same dashboards. Pi 5 has a known
  thermal-throttle threshold of 80 °C (configurable); set the warn at
  70 °C, crit at 78 °C.
- **Anytime:** consider a cheap rack-area thermometer with a Prometheus
  exporter (e.g., a Pi running `dht22` reading) so you can correlate
  silicon temps with ambient. The same 5950X at 25 °C ambient vs 32 °C
  ambient is two different machines.

## References

- [ARCHITECTURE.md § 2.1](../../ARCHITECTURE.md) — the hardware whose
  thermals this runbook monitors.
- [ARCHITECTURE.md § 7.1](../../ARCHITECTURE.md) — the observability
  stack this runbook extends.
- [ARCHITECTURE.md § 7.2](../../ARCHITECTURE.md) — Phase 4 Alertmanager;
  the destination for the alerts this runbook seeds.
- [ARCHITECTURE.md § 3.3.1](../../ARCHITECTURE.md) — inter-VLAN matrix;
  the `cluster → mgmt` row gets `tcp/9100, tcp/9633` added (ADR-0017).
- [Runbook 04 § 6](./04-phase2-observability.md) — the
  `additionalScrapeConfigs` pattern this runbook copies for the host
  scrape.
- [Runbook 00b](./00b-proxmox-baseline-snapshot.md) — the Layer-2
  baseline this runbook's NvmeMediaErrors recipe falls back to.
- [Runbook 00c](./00c-power-failure-recovery.md) — companion hardware
  resilience runbook; this one watches *operating* health, that one
  ensures *recovery* health.
- [ADR-0011](../decisions/0011-phase1-single-pool-deviation.md) — the
  no-redundancy single-pool deviation that makes NvmeMediaErrors more
  load-bearing than it would be in a mirrored layout.
- [ADR-0015](../decisions/0015-cluster-dmz-2000-prometheus-cloudflared.md) —
  the precedent for adding a non-DaemonSet scrape target via firewall +
  `additionalScrapeConfigs`. ADR-0017 (created in Step 1.0) is the
  cluster→mgmt analogue.
- `MEMORY.md → psa_node_exporter_baseline_blocks.md` — clarifies that
  this runbook's host-side exporter does *not* run in any namespace and
  is therefore unaffected by PSA.
- `MEMORY.md → unifi_zone_firewall_gotchas.md` — the rule-ordering
  invariant the Step 1.1 placement must preserve.
