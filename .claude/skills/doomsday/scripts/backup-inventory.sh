#!/usr/bin/env bash
# Read-only inventory of what Longhorn's B2 backupstore can actually restore right
# now. One row per BackupVolume in longhorn-system; a BackupVolume with no
# lastBackupName has nothing to restore from, regardless of what the chart expects.
# See SKILL.md for why this needs to run before restore-volume.sh.
set -euo pipefail

# Must be a flat override, not an append: the sandbox's own NO_PROXY already
# includes 10.0.0.0/8 etc, which would make kubectl bypass the filtering proxy
# and get denied at connect() (see CLAUDE.md's "Cluster reads" section).
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="localhost,127.0.0.1"

KCTX="${KCTX:-homelab}"
KC=(kubectl --context "$KCTX")
JSON_OUT=0
[ "${1:-}" = "--json" ] && JSON_OUT=1

get_json() {
	local out
	if out="$("${KC[@]}" get "$@" -o json 2>/dev/null)"; then
		printf '%s' "$out"
	else
		printf '{"items":[]}'
	fi
}

backupvolumes_json="$(get_json backupvolumes.longhorn.io -n longhorn-system)"
backups_json="$(get_json backups.longhorn.io -n longhorn-system)"

# For each BackupVolume: pull namespace/pvcName out of status.labels.KubernetesStatus
# (a JSON string, so decoded with a second fromjson), and resolve the restore URL from
# the Backup named by status.lastBackupName rather than constructing it, since that's
# exactly the string Volume.spec.fromBackup expects. (BackupVolume.metadata.name has an
# extra hash suffix over the underlying volume name, so matching by name/volumeName
# instead of by lastBackupName silently matches nothing.)
jq -nr --argjson bv "$backupvolumes_json" --argjson b "$backups_json" --argjson json_out "$JSON_OUT" '
  ($b.items // []) as $backups
  | [ ($bv.items // [])[] | . as $vol
      | ($vol.status.labels.KubernetesStatus // "{}" | fromjson) as $ks
      | ($backups | map(select(.metadata.name == $vol.status.lastBackupName and .status.state == "Completed")) | last) as $backup
      | {
          backupVolume: $vol.metadata.name,
          namespace: ($ks.namespace // "unknown"),
          pvcName: ($ks.pvcName // "unknown"),
          size: ($vol.status.size // "0"),
          accessMode: ($vol.status.labels["longhorn.io/volume-access-mode"] // "rwo"),
          lastBackupName: ($vol.status.lastBackupName // ""),
          lastBackupAt: ($vol.status.lastBackupAt // ""),
          url: ($backup.status.url // "")
        }
    ]
  | if $json_out == 1 then tojson else
      (.[] | if .lastBackupName == "" or .url == "" then
          "\(.namespace)/\(.pvcName)\t\(.backupVolume)\tNO RESTORABLE BACKUP"
        else
          "\(.namespace)/\(.pvcName)\t\(.backupVolume)\t\(.size)B\t\(.accessMode)\t\(.lastBackupAt)\t\(.lastBackupName)"
        end)
    end
'
