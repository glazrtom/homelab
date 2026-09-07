# Observability & monitoring stack

## Context

The homelab currently has **black-box availability monitoring only**: `gatus/` probes ~12
internal endpoints plus one edge check with cert expiry, receives a daily Longhorn backup
heartbeat via `external-endpoints`, and emails on failure. That answers "is it up" well and
cheaply (13 MiB), but nothing in the cluster answers:

- Anything historical — `metrics-server` gives instantaneous values only. No trends, no
  post-mortems, no capacity planning.
- Host/SoC health — the node is an Orange Pi 5 (arm64, 8 cores, 8 GiB, ~256 GB boot device,
  Armbian/rockchip64). Nothing watches thermal throttling, disk wear, or filesystem fill.
- Kubernetes object state — a pod can `CrashLoopBackOff` or be `OOMKilled` repeatedly and
  still pass a gatus `/health` probe.
- ArgoCD app health — with `selfHeal: true`, a broken sync retries silently forever.
- Ingress traffic — request/5xx/latency per host, and who is probing the external class.
- **Node death is silent.** Everything watching the node, gatus included, runs *on* it. If
  the Pi or its uplink dies, the result is silence, not an alert.

The binding constraint is memory. The node is at **6.7 GiB / 7.9 GiB (84%)**, with pods
summing to 5.5 GiB — roughly **1.2 GiB of real headroom**. CPU is nearly idle (689m of
8000m, ~9%), so CPU is free and RAM is the entire design problem.

Intended outcome: a GitOps-managed Prometheus stack that closes the blind spots above,
fits the RAM budget, is guaranteed to outlive the workloads it monitors under pressure,
and scales to multiple nodes without redesign.

## Decisions already made

| Decision | Choice |
| --- | --- |
| Metrics stack | **Prometheus** (`kube-prometheus-stack`), not VictoriaMetrics |
| Rollout | **Phased** — metrics first, measure a week, then logs |
| Logs | **Loki + Grafana Alloy — authored but NOT deployed** (`enabled: false`) |
| TSDB storage | **Longhorn, short retention** |
| Alerting | **Alertmanager → ntfy** (deploy ntfy) |
| Alert rules | **Full defaults minus k3s-incompatible**, prune after a week of real firing |
| Dead-man switch | **healthchecks.io DaemonSet**, one check per node via slug auto-provisioning |
| Phase-1 scrape scope | Host, k8s platform, workload resources, storage, network/ingress, ArgoCD, meta-monitoring |
| Priority | Monitoring stack must be **evicted last**, not first |

## Key finding: use the `longhorn-bulk` StorageClass

The default `longhorn` StorageClass sets `recurringJobSelector` to the `protected` group
(`longhorn/values.yaml:96-98`), so **every PVC on it gets hourly + daily snapshots and a
nightly B2 backup**. That is the pathological case for a TSDB: Prometheus compaction
rewrites whole blocks every 2h, so each snapshot delta approaches the volume size, and the
nightly backup would ship constantly-rewritten blocks to B2 for data that is never actually
restored after a disaster.

`longhorn-bulk` (`longhorn/templates/storageclass-bulk.yaml`) already exists as the
no-snapshot, no-backup class — used by `jellyfin/`, `transmission/` and `media/` for media
PVCs. **Prometheus (and later Loki) PVCs go on `longhorn-bulk`.** This uses an existing repo
convention, needs no new Longhorn config, and is the whole mitigation for the write-
amplification concern.

## Architecture

A single wrapper chart `monitoring/` following the `longhorn/` precedent — a local chart
that vendors an upstream chart as a dependency and renders its own `lib.*` templates
alongside it.

```
monitoring/
  Chart.yaml            # deps: lib (file://../lib), kube-prometheus-stack, ntfy objects local
  Chart.lock
  values.yaml
  generate-secret.sh    # grafana admin password + healthchecks.io ping key
  templates/
    ingress.yaml                 # {{ include "lib.ingress" . }} -> Grafana
    service-authentik-outpost.yaml # {{ include "lib.authOutpost" . }}
    priorityclass.yaml
    ntfy.yaml                    # lib.deployment + lib.service + PVC
    heartbeat-daemonset.yaml     # healthchecks.io per-node ping
    servicemonitors.yaml         # longhorn, argocd, cloudflared, gatus, metallb
    sealed-secrets.yaml
    loki.yaml                    # authored, gated on .Values.loki.enabled (false)
    alloy.yaml                   # authored, gated on .Values.loki.enabled (false)
applications/core/monitoring.yaml
```

`applications/core/` rather than `applications/apps/` — this is cluster infrastructure.

## Implementation notes

### 1. The ArgoCD Application (`applications/core/monitoring.yaml`)

Copy `applications/core/longhorn.yaml`, which is the exact precedent for a large upstream
chart. It **must** carry:

- `syncOptions: [CreateNamespace=true, ServerSideApply=true, RespectIgnoreDifferences=true]`.
  `ServerSideApply=true` is mandatory — the `Prometheus` CRD alone exceeds the 262 kB
  annotation limit and the sync fails with `metadata.annotations: Too long` without it.
- `helm.valueFiles: [values.yaml, ../global/values.yaml]` — required, the chart references
  `.Values.global.*`.
- `ignoreDifferences` for the prometheus-operator admission webhook `caBundle`, same shape
  as the longhorn/metallb entries.
- `labels: {homelab/tier: core}`.

### 2. Eviction priority (explicit requirement)

- A `PriorityClass` `homelab-monitoring` at value `1000000`, applied to Prometheus,
  Alertmanager, Grafana, kube-state-metrics, node-exporter and ntfy.
- Set `requests == limits` on the Prometheus and Alertmanager pods so they land in
  **Guaranteed** QoS. Priority alone is not sufficient — the kubelet ranks eviction
  candidates by QoS class first, then priority.
- Together these make rallly and jellyfin the eviction targets, never the monitoring stack.

### 3. k3s incompatibilities — must be disabled or alerting is noise from minute one

`kube-prometheus-stack` ships ServiceMonitors and alerts for components that k3s runs inside
its single process and does not expose separately. Set to `false` in `values.yaml`:

```yaml
kubeControllerManager: {enabled: false}
kubeScheduler:         {enabled: false}
kubeProxy:             {enabled: false}
kubeEtcd:              {enabled: false}
```

Otherwise `KubeControllerManagerDown` / `KubeSchedulerDown` / `KubeProxyDown` fire
permanently. Per the "full defaults, then prune" decision, everything *else* stays on.

### 4. Prometheus sizing — load-bearing, not optional

- `scrapeInterval: 60s` (vs. the 15s default) — 4× fewer samples, 4× less RAM and disk.
- `retention: 15d` **and** `retentionSize` capped so it can never fill the boot device.
- `storageSpec` → `longhorn-bulk`, ~10 Gi.
- Aggressive `metricRelabelConfigs` drops, which is where the real savings are: cAdvisor
  histogram buckets, `apiserver_request_duration_seconds_bucket`, `etcd_*`, most `go_*` and
  `grpc_server_handled_total`. Keep the gauges, drop the buckets.
- Note: PVCs created from a StatefulSet `volumeClaimTemplate` are made by the StatefulSet
  controller, not ArgoCD, so the `Delete=false,Prune=false` annotation invariant does not
  apply to them — they are not ArgoCD-managed objects.

### 5. Phase-1 scrape targets (§1–6 + §9)

Native endpoints needing only a `ServiceMonitor` — no sidecars, which is what keeps this
inside the RAM budget:

| Target | Endpoint | Notes |
| --- | --- | --- |
| node-exporter | chart DaemonSet | enable `hwmon`, `thermal_zone`, `cpufreq` collectors for rockchip SoC/GPU temps and throttling; PSI from `/proc/pressure` |
| kube-state-metrics | chart | pod restarts, `OOMKilled`, pending pods, CronJob overdue |
| kubelet / cAdvisor | built in | per-container usage vs. requests vs. limits, CFS throttling |
| Longhorn | `longhorn-manager:9500` | volume actual size, snapshot count, robustness, backup status |
| ArgoCD | controller `:8082`, server `:8083`, repo `:8084` | app sync/health status |
| ingress-nginx | `:10254` | needs `controller.metrics.enabled: true` in `ingress/` for **both** classes |
| CoreDNS | `:9153` | built in |
| cloudflared | `--metrics` `:2000` | tunnel connection state |
| MetalLB | `:7472` | already runs a `frr-metrics` container |
| gatus | `/metrics` | set `metrics: true` in `gatus/values.yaml` — pulls existing black-box results into Grafana |
| Prometheus/Alertmanager | self | meta-monitoring; plus a grouped `up == 0` alert |

Deferred to phase 2 (each needs a per-app sidecar, so cost grows linearly): Authentik
`:9300`, `postgres_exporter`, Jellyfin, `exportarr` for the \*arr apps, `transmission-exporter`,
`pihole-exporter`, `smartctl_exporter`.

**Open item to check on the node:** whether the ~256 GB boot device is NVMe or eMMC. NVMe
gives rich SMART (wear %, media errors) via `smartctl_exporter`; eMMC gives only a coarse
lifetime estimate via `mmc-utils` + node-exporter's textfile collector. This changes the
phase-2 approach to disk-wear monitoring.

### 6. Alerting: Alertmanager → ntfy → phone

- ntfy deployed from `lib.deployment`/`lib.service` with a small `longhorn` PVC (config is
  worth snapshotting, unlike metrics), reachable internally only.
- Alertmanager `webhook_configs` posts to `http://ntfy.monitoring/<topic>`.
- Keep the existing gatus → Gmail SMTP path untouched; the two systems alert independently,
  which is a feature — a failure in one does not silence the other.
- Route the always-firing **`Watchdog`** alert to the healthchecks.io check below, so the
  alerting pipeline monitors itself: if Prometheus or Alertmanager dies, the ping stops.

### 7. healthchecks.io dead-man switch (DaemonSet)

A DaemonSet sharing one ping URL is worse than useless — a surviving node keeps the check
green while another is dead. Instead:

- Use healthchecks.io **slug-based ping with auto-provisioning**
  (`/ping/<key>/<slug>`), building the slug from the node name via the downward API
  (`spec.nodeName` → `NODE_NAME`).
- One sealed ping key, one DaemonSet, every node self-registers as its own check. Scales to
  N nodes with zero per-node config.
- Container is a minimal image looping `curl` on an interval; ~5 MiB.

### 8. Grafana access

Follow the `longhorn`/`pihole` pattern rather than the OIDC one — simpler and consistent:

- `ingress: {enabled: true, external: true, auth: true}` in `monitoring/values.yaml`.
- `service: {name: monitoring-grafana, port: 80}` — the `lib.serviceName` override
  (`lib/templates/_helpers.tpl:24`) points `lib.ingress` at the subchart's Service, exactly
  as `longhorn/values.yaml:7-9` does.
- Add a `gatedApps` entry to `authentik/values.yaml` (`slug: grafana`, `group:
  homelab-admins`) and render `lib.authOutpost` — **mandatory**, both ingress classes are
  deny-by-default and `lib.ingress` `fail`s without `ingress.auth`.
- Grafana `auth.proxy` maps the `X-authentik-username` header the outpost already sets, so
  SSO identity carries into Grafana without a second login.
- Admin password sealed via `generate-secret.sh` + `scripts/seal.sh`.

### 9. Loki + Alloy — authored, not deployed

Write `templates/loki.yaml` and `templates/alloy.yaml` complete and correct, gated on
`{{- if .Values.loki.enabled }}` with `loki.enabled: false` in `values.yaml`. Chart
dependencies use a matching `condition:` so the subcharts are not even rendered. Loki PVC
targets `longhorn-bulk` for the same reason as Prometheus. Enabling later is a one-line
values change once a week of real memory data confirms the headroom.

## Verification

1. **Template before anything else** (mandatory per CLAUDE.md):
   `helm dependency build monitoring/` then
   `helm template monitoring/ -f global/values.yaml -f monitoring/values.yaml`
   Confirm: Loki/Alloy render *nothing*, both Grafana Ingresses appear with auth
   annotations, PVCs say `longhorn-bulk`, and the PriorityClass is present.
2. `yamllint applications/core/monitoring.yaml`
3. Re-template `authentik/` and `ingress/` after editing their values.
4. After sync: `mcp__kubernetes__pods_top` to confirm actual stack memory against the
   ~1.2 GiB budget — this number decides whether Loki gets enabled.
5. Check Prometheus `/targets` for targets down; confirm no `Kube{Scheduler,Proxy,ControllerManager}Down`
   alerts are firing.
6. Verify the Watchdog alert reaches healthchecks.io and a test alert reaches ntfy.
7. Confirm no Longhorn snapshots are being created for the Prometheus volume (the whole
   point of `longhorn-bulk`).
8. Let the default ruleset run for a week, then prune what fired uselessly.
