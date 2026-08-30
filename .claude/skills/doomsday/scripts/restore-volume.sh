#!/usr/bin/env bash
# Restores exactly one Longhorn volume from its B2 backup into a statically-bound
# PV/PVC pair the target chart's own PVC name, so ArgoCD adopts it as pre-existing
# data instead of provisioning an empty one. Idempotent - safe to re-run.
#
# Usage: restore-volume.sh <backupvolume-name>
# Run `backup-inventory.sh` first to get the backupvolume name and confirm it has
# a restorable backup. See SKILL.md for why this must run between
# ansible/playbooks/cluster.yml and ansible/playbooks/apps.yml.
set -euo pipefail

export NO_PROXY="localhost,127.0.0.1"
export no_proxy="localhost,127.0.0.1"

KCTX="${KCTX:-homelab}"
KC=(kubectl --context "$KCTX")
LH_NS=longhorn-system

BV_NAME="${1:?Usage: restore-volume.sh <backupvolume-name> (see backup-inventory.sh)}"

bv_json="$("${KC[@]}" -n "$LH_NS" get backupvolumes.longhorn.io "$BV_NAME" -o json)"
namespace="$(jq -r '.status.labels.KubernetesStatus // "{}" | fromjson | .namespace // empty' <<<"$bv_json")"
pvc_name="$(jq -r '.status.labels.KubernetesStatus // "{}" | fromjson | .pvcName // empty' <<<"$bv_json")"
size="$(jq -r '.status.size // empty' <<<"$bv_json")"
access_mode="$(jq -r '.status.labels["longhorn.io/volume-access-mode"] // "rwo"' <<<"$bv_json")"
last_backup="$(jq -r '.status.lastBackupName // empty' <<<"$bv_json")"

if [ -z "$namespace" ] || [ -z "$pvc_name" ]; then
	echo "error: could not resolve namespace/pvcName from $BV_NAME's KubernetesStatus label" >&2
	exit 1
fi
if [ -z "$last_backup" ]; then
	echo "error: $BV_NAME has no lastBackupName - NO RESTORABLE BACKUP, nothing to restore" >&2
	exit 1
fi

backup_url="$("${KC[@]}" -n "$LH_NS" get backups.longhorn.io "$last_backup" -o jsonpath='{.status.url}')"
backup_state="$("${KC[@]}" -n "$LH_NS" get backups.longhorn.io "$last_backup" -o jsonpath='{.status.state}')"
if [ "$backup_state" != "Completed" ] || [ -z "$backup_url" ]; then
	echo "error: $last_backup is not Completed (state=$backup_state) - refusing to restore from it" >&2
	exit 1
fi

VOL_NAME="restored-${namespace}-${pvc_name}"
PV_NAME="${VOL_NAME}-pv"

echo "Restoring $namespace/$pvc_name from $last_backup into volume $VOL_NAME ..." >&2

# Volume: created statically from the backup, so it does NOT inherit the labels the
# `longhorn` StorageClass stamps on volumes it provisions. Without these two labels
# the restored volume silently drops out of backup-daily forever.
cat <<EOF | "${KC[@]}" apply -f -
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: $VOL_NAME
  namespace: $LH_NS
  labels:
    recurring-job-group.longhorn.io/protected: enabled
    backup-target: default
spec:
  size: "$size"
  accessMode: $access_mode
  numberOfReplicas: 1
  dataEngine: v1
  frontend: blockdev
  fromBackup: "$backup_url"
  backupTargetName: default
  staleReplicaTimeout: 30
EOF

echo "Waiting for $VOL_NAME to finish restoring (this can take a while for large volumes) ..." >&2
for _ in $(seq 1 120); do
	state="$("${KC[@]}" -n "$LH_NS" get volumes.longhorn.io "$VOL_NAME" -o jsonpath='{.status.state}' 2>/dev/null || true)"
	restore_required="$("${KC[@]}" -n "$LH_NS" get volumes.longhorn.io "$VOL_NAME" -o jsonpath='{.status.restoreRequired}' 2>/dev/null || true)"
	if [ "$state" = "detached" ] && [ "$restore_required" = "false" ]; then
		break
	fi
	sleep 5
done
if [ "$state" != "detached" ] || [ "$restore_required" != "false" ]; then
	echo "error: $VOL_NAME did not finish restoring (state=$state restoreRequired=$restore_required)" >&2
	exit 1
fi

"${KC[@]}" get namespace "$namespace" >/dev/null 2>&1 || "${KC[@]}" create namespace "$namespace"

# PV/PVC: modelled on the existing static shared-media pairs (e.g.
# transmission/templates/pvc-media.yaml). volumeName is safe to set explicitly -
# Kubernetes populates it on every bound PVC regardless, which is why ArgoCD reports
# chart-rendered PVCs as Synced even though the charts never set it themselves.
k8s_access_mode="ReadWriteOnce"
[ "$access_mode" = "rwx" ] && k8s_access_mode="ReadWriteMany"

cat <<EOF | "${KC[@]}" apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV_NAME
  annotations:
    argocd.argoproj.io/sync-options: Delete=false,Prune=false
spec:
  capacity:
    storage: ${size}
  accessModes:
    - $k8s_access_mode
  persistentVolumeReclaimPolicy: Retain
  storageClassName: longhorn
  volumeMode: Filesystem
  claimRef:
    namespace: $namespace
    name: $pvc_name
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: $VOL_NAME
    volumeAttributes:
      numberOfReplicas: "1"
      staleReplicaTimeout: "30"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_name
  namespace: $namespace
  annotations:
    argocd.argoproj.io/sync-options: Delete=false,Prune=false
spec:
  storageClassName: longhorn
  accessModes:
    - $k8s_access_mode
  resources:
    requests:
      storage: ${size}
  volumeName: $PV_NAME
EOF

echo "Restored $namespace/$pvc_name. Confirm its size/accessMode match what" >&2
echo "'helm template <chart>/ -f global/values.yaml -f <chart>/values.yaml' renders" >&2
echo "before running apps.yml - a mismatch on an immutable PVC field fails ArgoCD's sync." >&2
