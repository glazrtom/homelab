#!/usr/bin/env bash
# Collects read-only Longhorn/kubelet storage data into one JSON snapshot under
# reports/. See SKILL.md for why this pulls from multiple sources instead of one.
set -euo pipefail

# Must be a flat override, not an append: the sandbox's own NO_PROXY already
# includes 10.0.0.0/8 etc, which would make kubectl bypass the filtering proxy
# and get denied at connect() (see CLAUDE.md's "Cluster reads" section).
export NO_PROXY="localhost,127.0.0.1"
export no_proxy="localhost,127.0.0.1"

KCTX="${KCTX:-homelab}"
KC=(kubectl --context "$KCTX")

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
OUT_DIR="$REPO_ROOT/reports"
mkdir -p "$OUT_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="$OUT_DIR/$TS.json"

# get_json <label> <kubectl-get-args...> -- prints JSON or "null" on any failure
# (missing CRD, RBAC denial, etc.) so one absent resource never aborts the run.
get_json() {
	local out
	if out="$("${KC[@]}" get "$@" -o json 2>/dev/null)"; then
		printf '%s' "$out"
	else
		printf 'null'
	fi
}

get_raw() {
	local out
	if out="$("${KC[@]}" get --raw "$1" 2>/dev/null)"; then
		printf '%s' "$out"
	else
		printf 'null'
	fi
}

volumes_json="$(get_json volumes.longhorn.io -n longhorn-system)"
snapshots_json="$(get_json snapshots.longhorn.io -n longhorn-system)"
backups_json="$(get_json backups.longhorn.io -n longhorn-system)"
backupvolumes_json="$(get_json backupvolumes.longhorn.io -n longhorn-system)"
backuptargets_json="$(get_json backuptargets.longhorn.io -n longhorn-system)"
lhnodes_json="$(get_json nodes.longhorn.io -n longhorn-system)"
recurringjobs_json="$(get_json recurringjobs.longhorn.io -n longhorn-system)"

# One stats-summary blob per k8s node — the only source of real filesystem usage.
node_names="$("${KC[@]}" get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
stats_array="[]"
for node in $node_names; do
	stats="$(get_raw "/api/v1/nodes/$node/proxy/stats/summary")"
	if [ "$stats" != "null" ]; then
		stats_array="$(jq -c --argjson acc "$stats_array" --arg node "$node" --argjson s "$stats" \
			'$acc + [{node: $node, stats: $s}]' <<<'{}')"
	fi
done

jq -n \
	--arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--arg kctx "$KCTX" \
	--argjson volumes "$volumes_json" \
	--argjson snapshots "$snapshots_json" \
	--argjson backups "$backups_json" \
	--argjson backupvolumes "$backupvolumes_json" \
	--argjson backuptargets "$backuptargets_json" \
	--argjson lhnodes "$lhnodes_json" \
	--argjson recurringjobs "$recurringjobs_json" \
	--argjson nodeStats "$stats_array" \
	'{
		collected_at: $collected_at,
		kubectl_context: $kctx,
		volumes: $volumes,
		snapshots: $snapshots,
		backups: $backups,
		backupvolumes: $backupvolumes,
		backuptargets: $backuptargets,
		longhorn_nodes: $lhnodes,
		recurringjobs: $recurringjobs,
		node_stats: $nodeStats
	}' > "$OUT_FILE"

echo "$OUT_FILE"
