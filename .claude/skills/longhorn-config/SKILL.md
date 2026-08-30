---
name: longhorn-config
description: This skill should be used when changing Longhorn storage *configuration* in this homelab repo — PV/PVC/volume manifests, resizing the shared media volume or a config PVC, retiring or recovering a volume, or setting up/adjusting the B2 backup target and retention (RecurringJobs, recurringJobSelector, backupBlockSize). For a point-in-time report of *current* usage, snapshot overhead, or backup health, use the disk-report skill instead — this skill is about changing config, not reading live state.
---

# Longhorn storage configuration

Bulk media and per-app config both live on **Longhorn** (cluster-default StorageClass
`longhorn`, plus `longhorn-bulk` for statically-bound volumes — see `longhorn/`). The
media library is one Longhorn **RWX** volume (`longhorn/templates/volume-shared-media.yaml`,
sized via `global.sharedMedia`), genuinely shared across the `media`, `jellyfin` and
`transmission` namespaces: each namespace has its own static `PersistentVolume` pointing at the
same `csi.volumeHandle`, bound to that namespace's own PVC via `claimRef`. Config volumes
are plain dynamically-provisioned `longhorn` PVCs, one per app, following the
`pihole/templates/pvc-config.yaml` pattern. Resizing the shared volume is a two-line change
in `global/values.yaml` (`size` and `sizeBytes`, kept in sync); resizing a config PVC is a
one-line change to that app's `volume.config.size`. There is no host-path storage left in
any chart.

## Backups

Backups go from Longhorn to Backblaze B2 over the S3 backupstore
(`longhorn/templates/backuptarget.yaml`, gated by `backup.enabled`), scoped to the
`longhorn` StorageClass only. `persistence.recurringJobSelector` stamps every volume
that class provisions into the `protected` RecurringJobSelector group
(`longhorn/values.yaml`), which `longhorn/templates/recurringjobs.yaml`'s
`backup-daily`/`system-backup-weekly` jobs target; `longhorn-bulk` and the static
`shared-media` volume set no selector, so bulk media is never uploaded. Credentials
are sealed via `longhorn/generate-b2-secret.sh`, following the same pattern as the
other `generate-*-secret.sh` scripts (see the `secrets` skill). For restoring a volume
*from* one of these backups after total node loss, see the `doomsday` skill — this
skill only covers producing and retaining backups, not restoring from them.

Two things not to change without re-reading why — this is rejected-design rationale,
not just current state:

- **No S3 Object Lock on the backupstore bucket.** Longhorn's backupstore is not
  append-only — it rewrites `volume.cfg` on every backup and deletes/garbage-collects
  blocks to enforce each RecurringJob's `retain` count. A default Object Lock
  retention period (compliance *or* governance mode — Longhorn's driver never sends
  `x-amz-bypass-governance-retention`) makes both operations fail. Use B2's SSE-B2
  bucket-level encryption instead; there is no backup-level encryption in Longhorn
  itself.
- **No age-based B2 lifecycle rule on current objects** (`daysFromUploadingToHiding`
  must stay unset). Longhorn owns retention via each RecurringJob's `retain` count;
  a B2-side age rule would delete blocks a newer incremental backup still
  references and silently corrupt the chain. `daysFromHidingToDeleting` (aging out
  versions Longhorn has already deleted) is safe and gives an undelete window.

Also note `backupBlockSize` is immutable per volume (fixed at creation), so changing
`longhorn.defaultSettings.defaultBackupBlockSize` only affects volumes created
afterward, never retroactively resizing existing ones.

## Deletion protection and volume retirement

Every rendered PV/PVC carries `argocd.argoproj.io/sync-options: Delete=false,Prune=false`
(`lib.pvc` in `lib/templates/_pvc.tpl` for config volumes; each shared-media/calibre chart's
hand-written `pvc-*.yaml` for the rest). This means neither an ordinary prune nor deleting the
owning Application (e.g. renaming an ApplicationSet generator element — see the
"never rename a generator element in place" pitfall in the root CLAUDE.md) can remove a
data volume; retiring one for real is a manual two-step:
`kubectl delete pvc`, then delete the now-`Released` PV and its Longhorn volume. Config PVCs
are dynamically provisioned (Longhorn keys the volume off the PVC's UID), so a PVC that does
get deleted and recreated comes back **empty** even with the same name — recovering the data
means binding a temporary PVC to the orphaned (`Retain`ed) PV and copying it across, since it
does not rejoin automatically like the static shared-media volumes do.
