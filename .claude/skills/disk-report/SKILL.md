---
name: disk-report
description: This skill should be used when the user wants a point-in-time READ of current Longhorn state — a disk usage report, storage report, how full the cluster's volumes are right now, how much space snapshots are consuming over the real data size, or whether Longhorn backups are currently healthy/succeeding/recent enough. Triggers on phrases like "disk usage", "storage report", "how full are the volumes", "snapshot overhead", "are backups working", "check backups", "/disk-report". For CHANGING storage configuration (resizing a volume, editing PV/PVC manifests, setting up the backup target or retention policy) use the longhorn-config skill instead — this skill only reads and reports, it never modifies anything.
---

# Disk usage report

Produces a point-in-time report of Longhorn volume usage, snapshot overhead, backup
health, node disk pressure, and growth trend since the last run. Strictly read-only
against the cluster — no `kubectl apply`/`delete`/`patch` of any kind.

## Why this needs two data sources (read before "simplifying")

`volumes.longhorn.io` `.status.actualSize` is **not** filesystem usage — it's total
blocks consumed across the whole snapshot chain, and it can exceed the volume's
nominal size. Real filesystem usage only comes from the kubelet stats-summary API
(`/api/v1/nodes/<node>/proxy/stats/summary`). The report needs **both**:

- `usedBytes` (kubelet stats) = what's actually on disk right now → the "% used" figure.
- `actualSize` (Longhorn volume) = usedBytes + every retained snapshot's delta.
- `actualSize - usedBytes` = snapshot overhead, the number this report exists to surface.

Collapsing this back to one source silently reports snapshot bloat as if it were live
data usage (or vice versa) — don't.

## Steps

1. Run `bash .claude/skills/disk-report/scripts/collect.sh`. It prints the path of the
   JSON snapshot it just wrote under `reports/` (git-ignored). Each `kubectl` call is
   independently guarded — a missing CRD (e.g. no backups configured) degrades that
   section to `null` rather than aborting the run; note any such gaps to the user.
2. Run `bash .claude/skills/disk-report/scripts/render.sh <path-from-step-1>`. It
   auto-selects the most recent *other* snapshot in `reports/` for the trend column
   (skip this if only one snapshot exists — the script will say so), computes every
   percentage itself, and prints markdown to stdout while also saving it next to the
   JSON.
3. Print that markdown to the user verbatim. Then add a short paragraph above it (not
   inside the machine output) calling out what to act on first and why — lead with
   anything in the Action Items section, especially `NO RESTORABLE BACKUP` markers,
   before percentages-near-threshold.

## Thresholds (env-overridable, see script defaults)

`WARN_PCT` (75), `CRIT_PCT` (90), `SNAP_OVERHEAD_WARN_PCT` (50),
`BACKUP_MAX_AGE_HOURS` (26 — matches `longhorn/values.yaml` `backup.report.windowHours`),
`NODE_WARN_PCT` (80), `PROJECT_DAYS_WARN` (30). Pass them as env vars to `render.sh` if
the user asks for different sensitivity, e.g. `WARN_PCT=60 bash .../render.sh <file>`.

## Notes

- The shared `shared-media` Longhorn volume is mounted via a separate PV/PVC in each
  of `media`, `jellyfin`, and `transmission` (see CLAUDE.md's Storage section).
  Its row's `Volume` label reflects whichever namespace Longhorn's `kubernetesStatus`
  happens to report that run and can change between runs — this is cosmetic, not a
  data error; the usage figures themselves are identical across every mount since
  they're the same underlying filesystem.
- A volume with no `recurring-job-group.longhorn.io/protected` label (currently
  `shared-media` and anything on `longhorn-bulk`) is reported as **unprotected by
  design**, not as a warning — per `longhorn/values.yaml` those are deliberately
  excluded from backup.
- `KCTX` env var overrides the kubectl context (default `homelab`).
- Cluster calls need the `NO_PROXY`/`no_proxy` prefix per this repo's CLAUDE.md;
  `collect.sh` sets it itself, so just run the scripts as shown above.
