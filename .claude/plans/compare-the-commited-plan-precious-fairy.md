# SigNoz vs. the committed Prometheus plan

## Context

`.claude/plans/let-s-think-about-observability-immutable-sundae.md` (committed as `3181cf6`)
specifies a `kube-prometheus-stack` wrapper chart under `monitoring/`, phased so Loki+Alloy
are authored but disabled. The open question is whether SigNoz — an OTel-native,
ClickHouse-backed single-pane platform covering metrics, logs and traces — would be a better
fit for this homelab.

Conclusion up front: **no.** Keep the committed plan. SigNoz loses on all three axes that
actually bind here (RAM, GitOps declarability, workload instrumentability), and its one real
advantage — unified logs+traces — is either unusable or already addressed by the phased Loki
step.

## The comparison

### 1. RAM — the stated binding constraint

The committed plan's whole design premise is **~1.2 GiB of real headroom** (node at
6.7/7.9 GiB, pods summing to 5.5 GiB), which is why it picks a 60s scrape interval, aggressive
`metricRelabelConfigs` bucket drops, and defers Loki until a week of measurement.

SigNoz's default chart requests look cheap (ClickHouse `100m/200Mi`, ZooKeeper `100m/256Mi`,
otel-collector `100m/200Mi`, SigNoz core `100m/100Mi`) but those are floors, not working sets.
Steady-state RSS for ClickHouse + ZooKeeper + collector + core lands around **2.5–3.5 GiB**,
and SigNoz's own capacity-planning table starts at 4 vCPU / 16 GiB for the general-purpose
half and 16 vCPU / 32 GiB for ClickHouse. A `kube-prometheus-stack` tuned as the plan
describes fits in roughly **600–900 MiB**.

That is 3–5× the budget. To run SigNoz you would evict rallly and jellyfin to make room for
the thing watching them — inverting the plan's explicit "monitoring evicted last" requirement.

If RAM footprint is the concern driving this question, the lever is **VictoriaMetrics**
(already considered and rejected in the plan), not SigNoz. SigNoz is the opposite direction on
that axis.

### 2. GitOps declarability — the repo's core premise

This repo is 100% declarative YAML synced by ArgoCD with `prune` + `selfHeal`. `kube-prometheus-stack`
matches that natively: `ServiceMonitor`, `PodMonitor`, `PrometheusRule` and Grafana
sidecar-loaded dashboard ConfigMaps are all CRDs/objects that live in git and reconcile.

SigNoz stores dashboards, alert rules and notification channels in its **internal metadata DB**,
managed through its UI/API. There are no CRDs. Everything you configure is cluster state
outside git — the exact thing this repo exists to avoid — and a lost PVC loses your entire
alerting config with no `git checkout` to recover it. Also, the plan's `longhorn-bulk`
insight becomes harder to apply: metrics blocks are disposable, but SigNoz's metadata DB is
*not*, so you'd need split storage classes across its components.

### 3. Signal shape — the blind spots are Prometheus-shaped

Every gap the plan enumerates emits Prometheus metrics: node-exporter (rockchip thermals,
PSI), kube-state-metrics (`OOMKilled`, CrashLoop), `longhorn-manager:9500`, ArgoCD
`:8082/8083/8084`, ingress-nginx `:10254`, CoreDNS `:9153`, cloudflared `:2000`, MetalLB
`:7472`, gatus `/metrics`. SigNoz can ingest these via its collector's `prometheusreceiver`,
but you then throw away the ecosystem built on top of them: ~100 curated community alert
rules (the plan's "full defaults, prune after a week" strategy is only cheap because those
rules exist), and the ready-made Grafana dashboards for node-exporter, Longhorn, ingress-nginx
and ArgoCD. On SigNoz you hand-author all of that, by hand, in a UI.

### 4. SigNoz's flagship feature is unusable here

Distributed tracing is what justifies the ClickHouse footprint. But **there is no application
source code in this repo** — every workload is a third-party image (Jellyfin, Pi-hole, the
\*arr apps, Authentik, transmission, rallly). None emit OTLP traces and none can be
instrumented. You would pay ClickHouse's full cost for a feature with zero producers.

### 5. Where SigNoz genuinely wins (and why it still doesn't matter)

- **Unified logs + metrics in one UI.** Real, but the plan already reaches this via Loki at
  a fraction of the RAM, gated behind a one-line `loki.enabled: true` after measurement.
- **Fewer conceptual moving parts** than operator + Loki + Alloy + Grafana. True, but traded
  against three stateful components (ClickHouse, ZooKeeper, metadata DB) doing heavy write
  amplification on Longhorn on a single arm64 SBC.
- **Future-proof if you ever write your own services.** Genuine, but revisit it then — not
  now, and probably not on this node.

## Recommendation

Proceed with the committed plan unchanged. Two small additions worth folding in:

1. Record this comparison as a "Decisions already made" row in
   `.claude/plans/let-s-think-about-observability-immutable-sundae.md`:
   `| OTel/tracing platform | **SigNoz rejected** — ~3–5× the RAM budget, no CRD-based GitOps for dashboards/alerts, and no instrumentable workloads to trace |`
2. If tracing ever becomes interesting, the cheap path is adding an OTLP receiver to the
   Prometheus stack later (Alloy already ships one, and it is authored in the plan's phase-2
   `templates/alloy.yaml`) rather than swapping platforms.

## Verification

No code change beyond the plan-file edit above, so validation is:

- `yamllint .claude/plans/*.md` is not applicable (markdown); nothing to `helm template`.
- The real verification is the committed plan's own step 4: after the Prometheus stack syncs,
  `mcp__kubernetes__pods_top` against the ~1.2 GiB budget. If the measured stack lands near
  600–900 MiB as expected, that also empirically confirms SigNoz never fit.

## Sources

- [SigNoz resources planning](https://signoz.io/docs/setup/capacity-planning/community/resources-planning/)
- [SigNoz chart defaults](https://github.com/SigNoz/charts/blob/main/charts/signoz/values.yaml)
- [SigNoz ClickHouse chart defaults](https://github.com/SigNoz/charts/blob/main/charts/clickhouse/values.yaml)
- [SigNoz architecture](https://signoz.io/docs/architecture/)
