#!/usr/bin/env bash
# Renders the markdown disk-usage report from a JSON snapshot produced by
# collect.sh. Auto-picks the most recent *other* snapshot in reports/ for the
# trend section unless PREV_SNAPSHOT is set.
set -euo pipefail

if [ $# -lt 1 ]; then
	echo "usage: render.sh <snapshot.json>" >&2
	exit 1
fi

CUR_FILE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REPORTS_DIR="$REPO_ROOT/reports"

WARN_PCT="${WARN_PCT:-75}"
CRIT_PCT="${CRIT_PCT:-90}"
SNAP_OVERHEAD_WARN_PCT="${SNAP_OVERHEAD_WARN_PCT:-50}"
BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-26}"
NODE_WARN_PCT="${NODE_WARN_PCT:-80}"
PROJECT_DAYS_WARN="${PROJECT_DAYS_WARN:-30}"

PREV_FILE="${PREV_SNAPSHOT:-}"
if [ -z "$PREV_FILE" ] && [ -d "$REPORTS_DIR" ]; then
	CUR_BASENAME="$(basename "$CUR_FILE")"
	PREV_FILE="$(ls -1 "$REPORTS_DIR"/*.json 2>/dev/null | grep -vF "$CUR_BASENAME" | sort | tail -n1 || true)"
fi

# Snapshots can be large enough to blow past ARG_MAX if passed inline as
# --argjson; --slurpfile reads straight from the file instead.
NULL_FILE="$(mktemp "${TMPDIR:-/tmp}/disk-report-null.XXXXXX")"
trap 'rm -f "$NULL_FILE"' EXIT
echo null > "$NULL_FILE"

PREV_SLURP="$NULL_FILE"
if [ -n "$PREV_FILE" ] && [ -f "$PREV_FILE" ]; then
	PREV_SLURP="$PREV_FILE"
fi

THRESHOLDS_JSON="$(jq -n \
	--argjson warn "$WARN_PCT" \
	--argjson crit "$CRIT_PCT" \
	--argjson snapOverheadWarn "$SNAP_OVERHEAD_WARN_PCT" \
	--argjson backupMaxAgeHours "$BACKUP_MAX_AGE_HOURS" \
	--argjson nodeWarn "$NODE_WARN_PCT" \
	--argjson projectDaysWarn "$PROJECT_DAYS_WARN" \
	'{warn: $warn, crit: $crit, snapOverheadWarn: $snapOverheadWarn, backupMaxAgeHours: $backupMaxAgeHours, nodeWarn: $nodeWarn, projectDaysWarn: $projectDaysWarn}')"

OUT_MD="${CUR_FILE%.json}.md"

jq -n -r \
	--slurpfile curArr "$CUR_FILE" \
	--slurpfile prevArr "$PREV_SLURP" \
	--argjson thresholds "$THRESHOLDS_JSON" \
	-f "$SCRIPT_DIR/render.jq" | tee "$OUT_MD"
