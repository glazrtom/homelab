---
name: doomsday
description: This skill should be used when the node has died or is being rebuilt from scratch and the goal is to get back to a working cluster with existing data intact — "the node died", "doomsday", "disaster recovery", "rebuild from scratch and restore", "restore from backup after a rebuild". For a routine fresh-host provision with no data to recover, use ansible-provisioning instead. For ordinary storage config changes (resizing, retention, the B2 target itself) use longhorn-config — this skill is about restoring existing volumes after total loss, not configuring backups.
---

# Doomsday: rebuild and restore

The one thing to get right: **restore Longhorn volumes between `ansible/playbooks/cluster.yml`
and `ansible/playbooks/apps.yml`**, not after. ArgoCD's `apps.yml` sync dynamically provisions
each app's config PVC via `lib.pvc` (`lib/templates/_pvc.tpl`), and Longhorn keys a dynamically
provisioned volume off the PVC's UID — so a PVC that comes up first and only later gets a volume
swapped under it does not pick up the restored data (see the `longhorn-config` skill's "PVC UID"
caveat). The PV/PVC pair has to already exist, statically bound to the restored volume, before
ArgoCD ever creates that PVC.

## Before you start

- **The git-ignored `<chart>/secrets/` plaintext dirs are the single biggest lever here.** If an
  off-machine copy of them exists (from the control node used for the last `apps.yml` run), the
  reseal step below is a pure re-encrypt and nothing rotates. Without them, every `--gen` secret
  in `ansible/roles/secrets/defaults/main.yml`'s 8 scripts re-mints randomly — see "Post-restore
  secret fixups" below for the consequences.
- Four credentials are human-supplied and have no local fallback if the plaintext is gone: GHCR
  PAT (`base/generate-secret.sh`), Windscribe username/password
  (`base/generate-windscribe-secret.sh`), the Gmail SMTP app password
  (`base/generate-smtp-secret.sh`), and the Backblaze B2 keyID/applicationKey
  (`longhorn/generate-b2-secret.sh`). **B2's applicationKey is shown once, at creation** — if both
  the plaintext and the cluster are gone, a new B2 key must be minted before anything can be
  restored at all, since the old key is unrecoverable and the bucket is otherwise inaccessible.
- The control node (wherever `ansible-playbook` runs from) needs `kubectl`, `helm`, `kubeseal`,
  `jq`, and `git` with push access to this repo. `cloudflared` needs a fresh interactive
  `cloudflared tunnel login` unless a saved `~/.cloudflared/cert.pem` survived.

## Order of operations

1. Reinstall the OS on the node; restore `10.0.0.1`, the hostname, and SSH access for `glazrtom`
   per `ansible/inventory.ini`.
2. `cd ansible && ansible-galaxy collection install -r requirements.yml --upgrade`
3. `ansible-playbook playbooks/cluster.yml -K` — provisions the host, k3s, and the cluster
   foundation (Helm, ArgoCD, sealed-secrets, Cloudflare), then applies `applications/core.yaml`.
   k3s is installed **unpinned** (`ansible/roles/k3s/defaults/main.yml` sets no
   `INSTALL_K3S_VERSION`), so check whatever version `get.k3s.io` served against Longhorn 1.12's
   support matrix before continuing if the rebuild happens much later than the original install.
4. `ansible-playbook playbooks/secrets.yml -K` — reseals all 8 secrets against the new
   sealed-secrets controller's key (the old key is not backed up anywhere; a fresh controller
   always mints a new one) and prompts to commit + **push**. This step is mandatory before
   Longhorn can even reach the backupstore: `longhorn-b2-credentials`
   (`longhorn/templates/sealed-b2.yaml`) is one of the 8. `ansible/group_vars/all.yml`'s
   `homelab_manifests_base` reads from GitHub `master`, so an unpushed commit stays invisible to
   ArgoCD. Leaving any prompt blank leaves that secret's committed sealed file undecryptable.
5. Wait for `BackupTarget/default` in `longhorn-system` to report available (up to its 300s
   `pollInterval`), then for `BackupVolume` CRs to appear as it syncs from B2.
6. `bash .claude/skills/doomsday/scripts/backup-inventory.sh` (read-only) — lists every
   `BackupVolume`, its target namespace/PVC, and whether it has a restorable backup. Anything
   marked `NO RESTORABLE BACKUP` cannot be recovered this way; it comes back empty when `apps.yml`
   provisions its PVC.
7. `bash .claude/skills/doomsday/scripts/restore-volume.sh <backupvolume-name>` for each
   restorable row — creates the Longhorn `Volume` from its latest `Completed` backup, waits for
   it to finish restoring, then a statically-bound `PersistentVolume`/`PersistentVolumeClaim` pair
   using the target chart's exact PVC name. Confirm the size/accessMode it restores match
   `helm template <chart>/ -f global/values.yaml -f <chart>/values.yaml` — a mismatch on an
   immutable PVC field fails ArgoCD's later sync rather than just warning.
8. `ansible-playbook playbooks/apps.yml -K` — ArgoCD adopts the pre-created PVCs as already
   satisfied instead of provisioning empty ones, then deploys every workload.
9. `ansible-playbook playbooks/storage.yml -K` if the `/mnt/storage` bulk disk is being reused.

`restore-volume.sh` always targets the backup's own recorded namespace/PVC name, and is safe to
run against a cluster where that namespace/PVC already exists and is live: the PVC's `spec` is
immutable once bound, so `kubectl apply` fails cleanly on the last step without touching the live
PVC or its data — it only succeeds where the target genuinely doesn't exist yet, i.e. a real
recovery. Confirmed against the live cluster while writing this skill: re-running it against
`gatus-data-pvc` (already bound) created and restored the Longhorn volume correctly, then errored
safely on the PVC step, leaving the running gatus pod untouched; the Volume/PV are also
straightforward to `kubectl delete` afterward, which is how that test was cleaned up.

## What does not come back

- **The shared 100Gi media library** (`shared-media`, mounted into `media`/`jellyfin`/
  `transmission`). It lives on the `longhorn-bulk` StorageClass with no recurring-job selector and
  is deliberately never uploaded to B2 (`longhorn/values.yaml`) — it must be re-acquired. Its
  directory tree self-heals: transmission's `initPerms` initContainer
  (`transmission/templates/_perms.tpl`) recreates and chowns `downloads/complete`,
  `downloads/incomplete`, `movies`, `series` under `global.sharedMedia.mountPath` on next start.
- k3s cluster state itself — no etcd snapshot is configured anywhere in this repo; recovery is
  "reprovision from ansible + git", not a state restore.
- Per the `argocd-ops` skill: the ArgoCD `github-actions` API token, the Cloudflare Access service
  token pair, and the GitHub repo secrets `ARGOCD_AUTH_TOKEN`/`CF_ACCESS_CLIENT_ID`/
  `CF_ACCESS_CLIENT_SECRET` — none of these round-trip through this repo and must be recreated by
  hand.

## Post-restore secret fixups (read before declaring done)

Resealing against a new controller key without the original plaintext means every `--gen` key
re-mints randomly — but the volumes just restored still hold data encrypted or authenticated with
the *old* values. Each `--unsafe-force` key in `authentik/generate-secret.sh` already documents
its own breakage via `--follow-up`; restated here because they're easy to miss once `apps.yml`
reports healthy:

- `AUTHENTIK_POSTGRESQL__PASSWORD` — `ALTER USER` the restored Postgres role to match the new
  value, then restart authentik.
- `AUTHENTIK_SECRET_KEY` — invalidates every authentik session immediately regardless.
- `LDAP_BIND_KEY` — pinned into the LDAP outpost provider; update it there too (see
  `authentik-ingress`).
- Both `JELLYFIN_OIDC_CLIENT_SECRET` and `JELLYFIN_OIDC_INTERNAL_CLIENT_SECRET` — pinned into
  Jellyfin's restored, PVC-stored plugin config (see `authentik-ingress`).
- `rallly/generate-secret.sh`'s `POSTGRES_PASSWORD`, `GARAGE_RPC_SECRET`,
  `GARAGE_DEFAULT_ACCESS_KEY`/`_SECRET_KEY` have the identical problem against restored rallly
  volumes.

None of this applies to a key whose plaintext survived off-machine — `secrets.yml` reseals it
as-is and nothing above rotates.

## Verifying the restore

Re-run `bash .claude/skills/disk-report/scripts/collect.sh` and `render.sh` (see the `disk-report`
skill) once `apps.yml` finishes — every volume that was restored should show as a normal Longhorn
volume with a recent `usedBytes`, and `backup-daily`/`snapshot-hourly` should pick it back up on
their next scheduled run since `restore-volume.sh` stamps the `protected` recurring-job-group
label. A volume missing that label silently stops being backed up going forward even though it
restored correctly once.
