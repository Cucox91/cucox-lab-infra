# Runbook 00c — Power-Failure Recovery (Hands-Off Restart)

> **Goal:** When utility power drops and returns, the Ryzen powers itself
> back on, ZFS imports cleanly, the Proxmox host comes up, every VM that
> should auto-start does, and every long-running service inside those VMs
> (k3s, cloudflared, Tailscale, node-exporter) is back without anyone
> walking to the rack.
>
> **Estimated time:** 30–45 minutes the first time (BIOS settings + per-VM
> audit + a real power-cut test). 5 minutes per node afterward whenever a
> new VM joins the lab.
>
> **When to run:** After [`00-phase0-proxmox-bootstrap.md`](./00-phase0-proxmox-bootstrap.md)
> and [`00b-proxmox-baseline-snapshot.md`](./00b-proxmox-baseline-snapshot.md)
> are done. Re-run the **Per-VM auto-start audit** (Step 5) any time a new
> VM is added or a service is added to an existing VM.
>
> **Operator:** Raziel, Mac Air on `CucoxLab-Mgmt` (VLAN 10), with at least
> one trip to the rack to set BIOS and run the power-cut test.

---

## The mental model: three failure modes, three layers of defense

A "the power blinked" event has three independent failure modes, each
defended by a different layer. Skipping any layer leaves a class of
outages where the lab does *not* recover hands-off.

| Failure mode | What goes wrong without the layer | Layer that defends |
|---|---|---|
| Host doesn't power back on at all | BIOS leaves the chassis in soft-off until someone hits the front-panel button | **BIOS — AC Power Recovery → Power On** (Step 2) |
| Host powers on but the OS doesn't boot cleanly | Dirty ZFS, fsck blocks at recovery prompt, GRUB lost the EFI entry | **OS resilience — ZFS import-cachefile, fsck behavior, boot-tool refresh** (Step 3) |
| Host is up but workloads aren't | A VM didn't auto-start, k3s wasn't `enabled`, cloudflared was started by hand once and never re-enabled | **Per-VM and per-service auto-start — Proxmox `onboot=1` + systemd `enable`** (Steps 4–5) |

A fourth, optional layer protects against the *cause* rather than the
*recovery*: a UPS that absorbs short brownouts and triggers a graceful
shutdown if the outage outlasts the battery. Strongly recommended; covered
in Step 6 as an optional add-on.

---

## What this runbook does NOT cover

- **The k3s control-plane quorum dance after a hard power-cut.** Three
  control-plane VMs all coming back at the same moment usually re-form
  the etcd cluster on their own; if one comes back materially later than
  the others (e.g., delayed BIOS POST), it joins as a follower without
  drama. Pathological cases (split-brain after a long outage with one CP
  permanently dead) are an incident-response topic, not a power-recovery
  one. See the future Phase 4 incident-response runbook.
- **Workload data consistency after a hard cut.** Apps with their own
  durability requirements (Mongo, Postgres, etc.) need their own crash-
  consistency story. Out of scope here; gets covered when those apps
  land in Phase 3.
- **Generator / whole-house ATS integration.** Out of scope. The lab is
  a single rack on a single circuit.

---

## Prerequisites

- Phase 0 runbook complete; `lab-prox01` reachable at `10.10.10.10` from
  the Mac Air on `CucoxLab-Mgmt` (VLAN 10).
- Physical access to the Ryzen for one BIOS reboot and one optional power-
  cut test (Step 7). The BIOS step can't be done remotely.
- A way to cut power deterministically for the test — easiest is the
  switch on a power strip the Ryzen is plugged into. If you go straight
  for the wall socket, fine; just be deliberate.

---

## Step 1 — Inventory what should auto-recover

Before changing anything, write down what *should* be running after a
clean reboot. This is the success criterion you'll use in Step 7.

```sh
ssh root@10.10.10.10 "qm list && pct list 2>/dev/null"
# Note every VMID that should be up after a reboot — at minimum the five
# k3s nodes and lab-edge01. Currently in Phase 1/2: lab-cp01..03, lab-wk01..02,
# lab-edge01.
```

Inside each VM, the per-service inventory you'll verify in Step 5:

| VM | Services that must auto-start |
|---|---|
| `lab-cp01..03`, `lab-wk01..02` | `k3s` (or `k3s-agent` on workers), `tailscaled` (per [runbook 06](./06-tailscale-proxmox-host-bootstrap.md) once joined), `node_exporter` (after [runbook 04](./04-phase2-observability.md)) |
| `lab-edge01` | `cloudflared`, `tailscaled` |
| `lab-prox01` (the host itself) | `pve-cluster`, `pveproxy`, `pvedaemon`, `pve-firewall`, `tailscaled` (per runbook 06), `zfs-import-cache`, `zfs-mount` |

If a service shows up here but is not currently `enabled` (Step 5
checks), the lab does not auto-recover today. That's the main remediation
this runbook delivers.

---

## Step 2 — BIOS: Restore on AC Power Loss → **Power On**

This is the load-bearing change. Without it, every other layer is moot —
the host stays in soft-off until someone presses the button.

1. Reboot the Ryzen and enter BIOS (Del or F2 on most boards; the Ryzen's
   board-specific key was noted in `00-phase0-proxmox-bootstrap.md`
   Step 5).
2. Find the setting. Naming varies by vendor — common labels:
   - **Restore on AC Power Loss** (ASUS, Gigabyte common)
   - **AC Power Recovery** / **Power-On After Power Failure** (MSI, ASRock)
   - **AC Back Function** (some Asrock)

   It usually lives under **Advanced → APM Configuration**, **Power**,
   or **Onboard Devices**. If you can't find it, search the motherboard
   manual PDF for "AC".
3. Set the value to **Power On**.

   The three options you'll typically see:

   | Value | Behavior | Use it when |
   |---|---|---|
   | **Power Off** (default on most boards) | Stays off; manual button press required | Never, for a homelab server |
   | **Last State** | Boots only if it was on when power dropped | OK as a fallback. Risk: if the host happened to be off (intentional shutdown for maintenance) when an outage hits, it stays off. |
   | **Power On** | Always boots when AC returns | **Recommended.** Always-on intent matches the lab's design. |
4. **Save and exit BIOS.** Do not skip this — settings are per-CMOS, not
   per-boot.
5. Take a phone photo of the BIOS screen showing the new value, and add
   it to `00b-phase0-baseline/bios-photos/` (per
   [`00b-proxmox-baseline-snapshot.md`](./00b-proxmox-baseline-snapshot.md)
   § Layer 5). Future-you replacing the motherboard will thank you.

While you're in BIOS, two related settings to confirm or set:

- **Wake on LAN** (often **PCI Devices Power On** or **Resume By PCI-E
  Device**): **Enabled.** Gives you a second way to wake the host
  remotely if Step 2's auto-power-on ever flakes after a board replace
  or a CMOS reset.
- **Boot order**: confirm the boot NVMe is first. A USB stick left
  plugged in (Clonezilla, Proxmox installer) shouldn't take precedence
  on next boot.

---

## Step 3 — OS: don't get stuck in fsck or a degraded ZFS prompt

A power-cut leaves the filesystem in a "needs recovery" state. ZFS handles
this transparently in the common case; the failure mode this step
defends against is **a configuration that drops to a recovery shell
instead of completing boot**.

### 3.1 ZFS import cache (verify, don't recreate)

The Proxmox installer sets this up correctly out of the box; we're
verifying it's still wired so a future config change doesn't silently
break it.

```sh
ssh root@10.10.10.10
systemctl is-enabled zfs-import-cache zfs-mount zfs.target
# Expect: enabled enabled enabled

ls -lh /etc/zfs/zpool.cache
# Expect: file present, non-empty (~1–2 KB).
```

If any unit is **disabled** or `zpool.cache` is missing, the host can
boot far enough to start ZFS but then fail to import `rpool` cleanly —
recoverable by hand from the console, but not hands-off. Re-enable:

```sh
systemctl enable zfs-import-cache zfs-mount zfs.target
zpool set cachefile=/etc/zfs/zpool.cache rpool
[ -n "$(zpool list -H -o name tank 2>/dev/null)" ] && \
  zpool set cachefile=/etc/zfs/zpool.cache tank
```

### 3.2 fsck behavior on the EFI / boot partition

The EFI System Partition is `vfat`; some configurations block boot at a
prompt if `fsck` finds errors. Confirm we're set to repair-and-continue:

```sh
grep -E '/(boot/efi|efi)' /etc/fstab
# Expect a line ending in "...,umask=0077 0 1" (the trailing 1 = fsck pass-on-boot).
```

If the trailing field is `0`, fsck never runs and a corrupted ESP can
silently break boot at the *next* reboot. If it's `1` and the fs has the
`errors=continue` option (Linux ext4 only — vfat doesn't have an
equivalent flag), boot proceeds. The Proxmox installer's default is
correct; verify, don't change.

### 3.3 systemd-boot vs GRUB (whichever you have): keep both ESPs synced

Proxmox can manage both ESPs (one per NVMe in a 2-disk install) via
`proxmox-boot-tool`. After a power-cut that may have left the previously-
written partition mid-flush:

```sh
proxmox-boot-tool status
# Expect every listed ESP to be "configured" with the same kernel version.

# Refresh once after this runbook completes (and after every kernel
# upgrade, which `proxmox-boot-tool refresh` runs automatically — but
# explicit verification is cheap):
proxmox-boot-tool refresh
```

A divergent ESP doesn't break *this* boot but makes the *next* boot
non-deterministic if BIOS picks the stale one.

---

## Step 4 — Proxmox: VMs auto-start on host boot

Per-VM `onboot` is what tells Proxmox to start a VM when the host comes
up. A new VM created via `qm create` defaults to `onboot=0`. Terraform-
provisioned VMs (per `terraform/proxmox/`) should set this explicitly —
check the module if you're not sure.

### 4.1 Audit current state

```sh
ssh root@10.10.10.10
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
  name=$(qm config "$vmid" | awk '/^name:/ {print $2}')
  onboot=$(qm config "$vmid" | awk '/^onboot:/ {print $2}')
  printf '%-6s %-20s onboot=%s\n' "$vmid" "$name" "${onboot:-0}"
done
```

Expected output:

```
100    lab-cp01             onboot=1
101    lab-cp02             onboot=1
102    lab-cp03             onboot=1
110    lab-wk01             onboot=1
111    lab-wk02             onboot=1
200    lab-edge01           onboot=1
```

(VMIDs are illustrative — match what `qm list` shows.)

Any VM showing `onboot=0` (or empty, which means 0) won't restart.

### 4.2 Set `onboot=1` for any VM that needs it

```sh
qm set <VMID> --onboot 1
```

### 4.3 Order VMs so the cluster comes up sanely

Default behavior is "start everything in parallel as fast as possible."
For a power-cut recovery this is *fine* in practice — k3s is robust to
control-plane peers showing up out of order — but if you'd rather have
the control plane settle before workers start hammering it, use start-
order and start-up-delay:

```sh
# Control plane first (lower order = earlier):
qm set 100 --startup order=1,up=30
qm set 101 --startup order=1,up=30
qm set 102 --startup order=1,up=30
# Workers second:
qm set 110 --startup order=2,up=15
qm set 111 --startup order=2,up=15
# Edge last (depends on cluster being up to be useful, but doesn't *need* it):
qm set 200 --startup order=3,up=0
```

`up=N` is "wait N seconds after this VM starts before starting the next
one in the same order." Tuned for a 5950X with NVMe — VMs hit "guest
agent reachable" in 15–25 s on a cold boot.

This is a polish step. The lab works without it; the lab is *more
predictable* with it.

### 4.4 Verify with a Proxmox-side reboot (still optional)

```sh
ssh root@10.10.10.10 "reboot"
# Then from the Mac Air, watch them come back:
watch -n 5 'for h in 10.10.20.21 10.10.20.22 10.10.20.23 10.10.20.31 10.10.20.32 10.10.30.21; do
  printf "%-15s " "$h"
  nc -z -w 2 "$h" 22 && echo "ssh up" || echo "down"
done'
```

A clean reboot of the host should bring all six VMs back to "ssh up"
within about two minutes. If one stays down, fix `onboot` for that VM
before doing the real power-cut test in Step 7.

---

## Step 5 — Per-VM auto-start audit (services inside the guest)

A VM that boots is not the same as a VM that's *running its job*. A
service started by hand (`systemctl start`) without being enabled
(`systemctl enable`) is **active** until the next reboot, then gone. This
is the single most common reason a homelab "doesn't come back" after a
power event — the operator started something during setup, never enabled
it, forgot.

### 5.1 The audit one-liner (run on every VM)

```sh
# From the Mac Air, for each VM IP:
for h in 10.10.20.21 10.10.20.22 10.10.20.23 10.10.20.31 10.10.20.32; do
  echo "=== $h ==="
  ssh ubuntu@"$h" 'systemctl list-unit-files --state=enabled,disabled | grep -E "^(k3s|cloudflared|tailscaled|node_exporter|prometheus-node-exporter)\.service" || echo "  (no matching services found)"'
done
echo "=== 10.10.30.21 (lab-edge01) ==="
ssh ubuntu@10.10.30.21 'systemctl list-unit-files --state=enabled,disabled | grep -E "^(cloudflared|tailscaled)\.service"'
```

Every line should end in **`enabled`**. Any line ending in `disabled` is
a hands-off-recovery hole.

### 5.2 Fix anything that's `disabled` but should be `enabled`

```sh
ssh ubuntu@<VM_IP> "sudo systemctl enable --now <service>"
```

`--now` ensures it's also running right now (idempotent if it already is).

### 5.3 Special cases

- **k3s on workers** is `k3s-agent.service`, not `k3s.service`. The audit
  pattern above misses that — adjust `grep` accordingly when you onboard
  workers, or use `systemctl is-enabled k3s k3s-agent 2>/dev/null` per
  node.
- **`pve-firewall.service`** on the host — must be `enabled` if you're
  using Proxmox's firewall (you are not in Phase 1; check is for future
  enablement).
- **Tailscale** — `tailscaled.service` should be `enabled`, and the node
  must already be authenticated. A node that auto-starts tailscaled but
  has an expired auth key boots into "logged out" and is unreachable
  over the tailnet. Re-auth before you assume the WoL fallback works.

---

## Step 6 (optional but strongly recommended) — UPS + NUT for graceful shutdown

The recovery path designed in Steps 1–5 is robust for *clean* power-
cycles. A *brownout* — voltage sags, repeated rapid cuts, or a long
outage that runs the OS through a hard kill while it's mid-write — is a
different failure class. The defense is a small UPS plus
[Network UPS Tools (NUT)](https://networkupstools.org/) so the OS sees
the power event and shuts down cleanly before the battery dies.

### 6.1 Sizing

For the Ryzen + 2.5 GbE switch + UCG-Max + small monitor (rare; usually
headless), a **CyberPower CP1500AVRLCD** or **APC Back-UPS Pro 1500**
gives you ~10–15 minutes of runtime under typical load. That is enough
to ride out 99% of residential outages and enough headroom to do a
graceful shutdown on the long ones.

> If you also want the home-network gear (ISP modem, UCG-Max) on the UPS
> so you keep internet during outages, factor that load in. The lab side
> alone draws roughly 100–150 W idle, 250–350 W under workload; double
> that for a comfortable runtime margin.

### 6.2 Wire the USB monitoring cable

Most consumer UPSes expose status over USB. Plug the UPS's USB cable
into the Ryzen's USB-A port. Then on the host:

```sh
ssh root@10.10.10.10
apt-get update && apt-get install -y nut nut-client nut-server
nut-scanner -U
# Expect: a stanza naming the UPS driver and the USB device path.
```

### 6.3 Configure NUT in standalone mode

NUT runs in three modes: standalone (single host), netserver (one host
shares status), netclient (multiple hosts subscribe). For one Ryzen,
**standalone** is the right call.

```sh
# /etc/nut/nut.conf
MODE=standalone

# /etc/nut/ups.conf — match driver/device from nut-scanner output:
[mainups]
    driver = usbhid-ups
    port = auto
    desc = "CyberPower CP1500AVRLCD"

# /etc/nut/upsmon.conf — shut down when battery < 30% or runtime < 180s:
MONITOR mainups@localhost 1 monuser <PASSWORD> master
SHUTDOWNCMD "/sbin/shutdown -h +0 'NUT: low battery, shutting down'"

# /etc/nut/upsd.users
[monuser]
    password = <PASSWORD>
    upsmon master
```

Generate `<PASSWORD>` once and SOPS-encrypt the relevant files into
`ansible/group_vars/lab-prox01/nut.enc.yaml` per
[ADR-0003](../decisions/0003-secrets-sops-age.md).

```sh
systemctl enable --now nut-server nut-monitor
upsc mainups@localhost
# Expect a key=value dump including battery.charge, ups.status (OL = on
# line, OB = on battery), input.voltage.
```

### 6.4 Pre-shutdown hook: drain VMs before the host shuts down

A graceful host shutdown by default sends `qm stop` to every running VM,
which is ACPI-shutdown — already much friendlier than yanking power. For
the k3s nodes specifically, you can have systemd cordon-and-drain them
ahead of the qm stop so kube-scheduler isn't surprised:

```sh
# /etc/systemd/system/k3s-pre-shutdown.service
[Unit]
Description=Cordon and drain k3s nodes before host shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
Conflicts=reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/k3s-drain-all.sh
TimeoutStopSec=120

[Install]
WantedBy=halt.target reboot.target shutdown.target
```

`k3s-drain-all.sh` is a 5-line script that uses the operator-on-Mac-Air
kubeconfig (or a kubeconfig copied to the host) to `kubectl cordon` and
`kubectl drain --ignore-daemonsets --delete-emptydir-data` each node.
Skip this in Phase 1 if it's premature; revisit when real workloads
land.

### 6.5 If you skip the UPS

You're betting that hard power-cuts during write activity won't corrupt
data. ZFS is unusually tolerant of this — the COW + uberblock design
means the worst case is "lose the last few seconds of writes," not "lose
the pool." But it does happen, and other in-VM filesystems (ext4 in
guests) are less forgiving. The UPS is cheap insurance; recommend it.

---

## Step 7 — Test it for real

Designed-but-untested recovery is no recovery. The whole point of this
runbook is that it works *under actual power loss*, which differs from a
soft `reboot` because:

- BIOS POST timing varies under real cold-start (capacitors discharge,
  fans spin up at full RPM, etc.).
- ZFS sees a *real* dirty pool, not a clean unmount.
- VMs see "qemu-process killed by SIGKILL" rather than a clean ACPI
  shutdown.

### 7.1 Pre-flight before pulling the plug

```sh
ssh root@10.10.10.10 "uptime && qm list && zpool status"
# Capture: uptime, every VM = "running", zpool = ONLINE, no resilver.
```

If anything is unhealthy before the test (a VM is stopped, a pool is
DEGRADED), fix it first — you want to know what *recovery* broke, not
inherit ambiguous state.

### 7.2 Take a Layer-1 ZFS snapshot first (10 seconds, free)

```sh
ssh root@10.10.10.10 "zfs snapshot -r rpool@pre-power-cut-test-$(date -u +%Y-%m-%d)"
# Cheap rollback target if the test goes badly. Hold it briefly per 00b
# § Layer 1, then release after the test passes.
```

### 7.3 Cut power

The deliberate way: switch off the power strip the Ryzen is plugged
into. **Not** the UPS (if you've added one — that defeats the test of
Steps 1–5). **Not** by `shutdown` (defeats the entire test).

Wait 30 seconds. Switch power back on.

### 7.4 Watch it come back

From the Mac Air on `CucoxLab-Mgmt`:

```sh
# Time to host SSH:
time bash -c 'until nc -z -w 2 10.10.10.10 22; do sleep 2; done; echo "host up"'
# Expected: 60–120 s on a 5950X + NVMe.

# Then per-VM:
watch -n 5 'for h in 10.10.20.21 10.10.20.22 10.10.20.23 10.10.20.31 10.10.20.32 10.10.30.21; do
  printf "%-15s " "$h"
  nc -z -w 2 "$h" 22 && echo "ssh up" || echo "down"
done'
```

Within ~3 minutes you should see all six rows reporting `ssh up`.

### 7.5 Verify the *services* are up, not just the *VMs*

```sh
# k3s control plane reachable from operator workstation:
kubectl get nodes
# Expect: 5 nodes Ready.

# cloudflared back online:
ssh ubuntu@10.10.30.21 "sudo systemctl is-active cloudflared"
# Expect: active

# Tailscale is back (test from outside the home network if you can):
ssh ubuntu@10.10.30.21 "tailscale status | head -5"
# Expect: own host shows IP, peers reachable.

# ZFS clean:
ssh root@10.10.10.10 "zpool status -x"
# Expect: "all pools are healthy"
```

If any of these fail, the corresponding earlier step missed something —
rerun the audit, re-enable the service, repeat the test.

### 7.6 Release the safety snapshot

```sh
ssh root@10.10.10.10 "zfs destroy -r rpool@pre-power-cut-test-$(date -u +%Y-%m-%d)"
```

---

## Step 8 — Document the result

Record the test outcome in your operator notebook (or in a project
`docs/log/` entry — if that pattern doesn't exist yet, this is a fine
excuse to start one). The minimum is:

- Date of test.
- BIOS setting confirmed at: **Power On** / **Last State**.
- UPS present: yes/no, model, NUT shutdown threshold.
- Time from power-on to all six VMs `ssh up`: e.g., 2m 14s.
- Anything that didn't recover automatically and what was fixed.

Re-run Step 7 (the actual power-cut) after every material lab change:
new VM added, kernel upgrade on the host, BIOS update, motherboard or
NVMe replacement.

---

## Restoration recipes (when recovery fails)

### "Host won't power on by itself"

- BIOS battery dead → CMOS reset → AC Power Recovery defaulted back to
  Off. Replace the CR2032, redo Step 2.
- BIOS update wiped settings. Same fix.
- PSU failure → no amount of BIOS config helps. Verify with paperclip
  test or a spare PSU; replace.

### "Host boots, drops to BusyBox initramfs prompt"

Most often: ZFS can't import `rpool`. From the prompt:

```sh
zpool import -f -N rpool
# If that errors, look at the error — usually a missing device by-id.
zpool import -d /dev/disk/by-id -f -N rpool
exit
```

If it imports cleanly that one time, fix the cachefile post-boot
(Step 3.1).

### "Host is up but a VM didn't auto-start"

```sh
ssh root@10.10.10.10
qm config <VMID> | grep onboot
# If empty or 0:
qm set <VMID> --onboot 1
qm start <VMID>
```

Then re-run Step 4.1 to see if any others were missed.

### "VM is up but a service didn't auto-start"

```sh
ssh ubuntu@<VM_IP> "sudo systemctl is-enabled <service>"
# If "disabled":
ssh ubuntu@<VM_IP> "sudo systemctl enable --now <service>"
```

Then re-run Step 5.1 to find any siblings.

### "Host stays off because it was off when power dropped, and you set Last State"

This is the trade-off you accepted. Either change BIOS to **Power On**
or use Wake-on-LAN from the Mac Air:

```sh
# One-time install:
brew install wakeonlan
# Then:
wakeonlan <RYZEN_MAC_ADDR>
```

The MAC address is the Ryzen's onboard NIC; capture it once via `ip link
show` and stash it in your operator notebook.

---

## What's done

- BIOS will auto-power-on the Ryzen when AC returns.
- ZFS imports cleanly via the persistent cachefile.
- Both ESPs are kept synced via `proxmox-boot-tool`.
- Every VM that should be running has `onboot=1`.
- Every service inside every VM that should be running is `enabled`.
- (Optional) UPS + NUT will trigger a graceful shutdown on long outages.
- A real power-cut test confirms end-to-end recovery in under ~3 minutes.

## What's next

- Add the optional [k3s pre-shutdown drain hook](#64-pre-shutdown-hook-drain-vms-before-the-host-shuts-down)
  once Phase 3 workloads exist and the cordon/drain dance is worth
  doing.
- After Phase 4 lands Alertmanager, add an alert on `node_boot_time_seconds`
  changing — so unplanned reboots page you instead of being noticed
  three days later.
- After Phase 5 brings the Pis online, repeat Steps 2 + 5 for each Pi
  (Pi 5 has a "Power → Power on after Power Loss" setting in its BIOS-
  equivalent EEPROM via `raspi-config`).

## References

- [ARCHITECTURE.md § 2.1](../../ARCHITECTURE.md) — Phase 1 hardware that
  this runbook hardens.
- [ARCHITECTURE.md § 11](../../ARCHITECTURE.md) — Phased plan; this
  runbook is a Phase 0 hardening step that protects every later phase.
- [Runbook 00 § 5.3](./00-phase0-proxmox-bootstrap.md) — the BIOS-config
  pass where SVM/IOMMU/Resizable BAR were set; this runbook adds the
  AC Power Recovery setting to that same pass.
- [Runbook 00b](./00b-proxmox-baseline-snapshot.md) — captures BIOS
  photos and the host config. Add the Step 2 photo to that baseline.
- [Runbook 06](./06-tailscale-proxmox-host-bootstrap.md) — Tailscale
  enablement; depends on `tailscaled.service` being `enabled` per
  Step 5.3.
- [ADR-0003](../decisions/0003-secrets-sops-age.md) — SOPS pattern used
  for the NUT password in Step 6.3.
- `MEMORY.md → feedback_security_over_speed.md` — the conservative
  posture this runbook reflects (test-then-trust, not trust-then-test).
