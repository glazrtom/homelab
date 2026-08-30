# Renders the disk-report markdown from one (or two, for trend) collected JSON
# snapshots. All arithmetic lives here so percentages are deterministic.
#
# Inputs:
#   --slurpfile curArr  : [current snapshot] (collect.sh output)
#   --slurpfile prevArr : [previous snapshot] or [null] if none
#   --argjson thresholds {...}

def fmtBytes($n):
	if $n == null then "—"
	elif $n < 0 then "-" + fmtBytes(-$n)
	elif $n == 0 then "0 B"
	else
		( [
			[$n, "B"],
			[($n/1024), "KiB"],
			[($n/1024/1024), "MiB"],
			[($n/1024/1024/1024), "GiB"],
			[($n/1024/1024/1024/1024), "TiB"]
		  ] ) as $units
		| ( if $n < 1024 then $units[0]
			elif $n < 1024*1024 then $units[1]
			elif $n < 1024*1024*1024 then $units[2]
			elif $n < 1024*1024*1024*1024 then $units[3]
			else $units[4] end ) as $u
		| ($u[0] * 100 | round | . / 100 | tostring) + " " + $u[1]
	end;

def pct($num; $den):
	if $den == null or $den == 0 then null else ($num * 1000 / $den | round / 10) end;

def pctStr($num; $den):
	pct($num; $den) as $p | if $p == null then "—" else ($p | tostring) + "%" end;

def ageHours($iso):
	if $iso == null or $iso == "" then null
	else ((($curArr[0]).collected_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
		- ($iso | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 3600
	end;

# --- build per-volume view ---

def volKS($v): $v.status.kubernetesStatus // {};

def volLabel($v):
	volKS($v) as $ks
	| if ($ks.namespace // "") != "" and ($ks.pvcName // "") != ""
		then $ks.namespace + "/" + $ks.pvcName
		else $v.metadata.name
		end;

def protected($v):
	($v.metadata.labels["recurring-job-group.longhorn.io/protected"] // "") == "enabled";

# flatten kubelet stats into {namespace, name} -> {used, cap}
def statsIndex:
	[ (($curArr[0]).node_stats // [])[].stats.pods[]? .volume[]? | select(.pvcRef != null)
	  | {key: (.pvcRef.namespace + "/" + .pvcRef.name), used: .usedBytes, cap: .capacityBytes} ]
	| map({(.key): {used, cap}}) | add // {};

def snapAgg:
	(($curArr[0]).snapshots.items // [])
	| group_by(.spec.volume)
	| map({
		key: .[0].spec.volume,
		count: length,
		totalSize: (map(.status.size // "0" | tonumber? // 0) | add),
		oldest: (map(.status.creationTime) | min)
	});

def backupAgg:
	(($curArr[0]).backups.items // [])
	| group_by(.metadata.labels["backup-volume"] // .status.volumeName // "unknown")
	| map({
		key: (.[0].metadata.labels["backup-volume"] // .[0].status.volumeName // "unknown"),
		newest: (sort_by(.metadata.creationTimestamp) | last)
	});

def bvIndex:
	[ (($curArr[0]).backupvolumes.items // [])[] | {key: .spec.volumeName, value: .status} ] | from_entries;

(($curArr[0]).volumes.items // []) as $vols
| statsIndex as $stats
| snapAgg as $snaps
| backupAgg as $backs
| bvIndex as $bvs
| ($thresholds) as $th

# --- action items ---
| [
	$vols[] |
	. as $v
	| volLabel($v) as $label
	| ($stats[$label].used) as $used
	| ($stats[$label].cap // ($v.spec.size | tonumber? // 0)) as $cap
	| pct($used; $cap) as $usedPct
	| (($v.status.actualSize // 0) - ($used // 0)) as $overhead
	| pct($overhead; $used) as $overheadPct
	| (($backs[] | select(.key == $v.metadata.name) | .newest) // null) as $newestBackup
	| [
		( if $v.status.robustness != null and $v.status.robustness != "healthy" then
			{sev: 0, msg: "\($label): volume robustness is \($v.status.robustness) (state \($v.status.state))"}
		  else empty end ),
		( if protected($v) and ($newestBackup == null or $newestBackup.status.state != "Completed") then
			{sev: 1, msg: ("\($label): NO RESTORABLE BACKUP" +
				(if $newestBackup != null then " (last attempt: \($newestBackup.status.state // "unknown"))" else " (none found)" end))}
		  else empty end ),
		( if $usedPct != null and $usedPct >= $th.crit then
			{sev: 2, msg: "\($label): \($usedPct)% used (critical, >= \($th.crit)%)"}
		  elif $usedPct != null and $usedPct >= $th.warn then
			{sev: 3, msg: "\($label): \($usedPct)% used (warning, >= \($th.warn)%)"}
		  else empty end ),
		( if $overheadPct != null and $used != null and $used > 0 and $overheadPct >= $th.snapOverheadWarn then
			{sev: 4, msg: "\($label): snapshot overhead \($overheadPct)% of live data (\(fmtBytes($overhead)) over \(fmtBytes($used)))"}
		  else empty end ),
		( if protected($v) and $newestBackup != null and $newestBackup.status.state == "Completed"
			and (ageHours($newestBackup.metadata.creationTimestamp) // 0) > $th.backupMaxAgeHours then
			{sev: 1, msg: "\($label): newest completed backup is \((ageHours($newestBackup.metadata.creationTimestamp) | round))h old (> \($th.backupMaxAgeHours)h)"}
		  else empty end )
	  ][]
  ] as $volumeActions

| ( [ (($curArr[0]).backuptargets.items // [])[] | select(.status.available != true)
	| {sev: 0, msg: "backup target \(.metadata.name) is UNAVAILABLE: \(.status.conditions[0].message // "unknown reason")"} ]
  ) as $btActions

| ( [ (($curArr[0]).longhorn_nodes.items // [])[] as $n
	| ($n.status.diskStatus // {}) | to_entries[] as $d
	| ($d.value.storageAvailable) as $avail
	| ($d.value.storageMaximum) as $max
	| pct($max - $avail; $max) as $usedPct
	| select($usedPct != null and $usedPct >= $th.nodeWarn)
	| {sev: 3, msg: "node \($n.metadata.name) disk \($d.key): \($usedPct)% used (warning, >= \($th.nodeWarn)%)"} ]
  ) as $nodeActions

| ( [$volumeActions[], $btActions[], $nodeActions[]] | sort_by(.sev) | map(.msg) ) as $actionItems

# --- previous snapshot index for trend ---
| ( if ($prevArr[0]) == null then null else
	[ (($prevArr[0]).node_stats // [])[].stats.pods[]? .volume[]? | select(.pvcRef != null)
	  | {key: (.pvcRef.namespace + "/" + .pvcRef.name), used: .usedBytes} ]
	| map({(.key): .used}) | add // {}
  end ) as $prevStats

| ( if ($prevArr[0]) == null then null else
	((($curArr[0]).collected_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)
		- (($prevArr[0]).collected_at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 86400
  end ) as $daysSincePrev

# --- render markdown ---
| "## Action Items\n" +
  ( if ($actionItems | length) == 0 then "- All clear — no thresholds exceeded.\n"
	else ($actionItems | map("- " + .) | join("\n")) + "\n" end ) +
  "\n## Volumes\n\n" +
  "| Volume | Used | Capacity | Used % | Allocated | Consumed (actualSize) | Snapshot overhead | Snapshots | Oldest snapshot | Health |\n" +
  "|---|---|---|---|---|---|---|---|---|---|\n" +
  ( [ $vols[] |
	. as $v
	| volLabel($v) as $label
	| ($stats[$label].used) as $used
	| ($stats[$label].cap // ($v.spec.size | tonumber? // 0)) as $cap
	| (($v.status.actualSize // 0) - ($used // 0)) as $overhead
	| (($snaps[] | select(.key == $v.metadata.name)) // null) as $snapInfo
	| ( if $v.status.state != "attached" then "*(detached — no live fs stats)*"
	    else "" end ) as $detachedNote
	| "| \($label) | \(fmtBytes($used))\($detachedNote) | \(fmtBytes($cap)) | \(pctStr($used; $cap)) | \(fmtBytes($v.spec.size | tonumber? // 0)) | \(fmtBytes($v.status.actualSize)) | \(fmtBytes($overhead)) (\(pctStr($overhead; $used))) | \($snapInfo.count // 0) | \(if $snapInfo.oldest then $snapInfo.oldest else "—" end) | \($v.status.robustness // "unknown")/\($v.status.state // "unknown") x\($v.spec.numberOfReplicas // "?") |"
  ] | join("\n") ) + "\n" +
  "\n## Backups\n\n" +
  ( (($curArr[0]).backuptargets.items // []) as $bts
    | if ($bts | length) == 0 then "*No BackupTarget found — backups may not be configured.*\n"
	  else ( $bts | map("- Target `\(.metadata.name)`: \(.spec.backupTargetURL) — " +
	  		(if .status.available then "available" else "**UNAVAILABLE**" end) +
	  		" (last synced \(.status.lastSyncedAt // "never"))") | join("\n") ) + "\n"
	end ) +
  "\n| Volume | Protected | Newest backup state | Age | Stored in target | Notes |\n" +
  "|---|---|---|---|---|---|\n" +
  ( [ $vols[] |
	. as $v
	| volLabel($v) as $label
	| protected($v) as $isProt
	| (($backs[] | select(.key == $v.metadata.name) | .newest) // null) as $nb
	| ($bvs[$v.metadata.name]) as $bv
	| "| \($label) | \(if $isProt then "yes" else "no (by design)" end) | \($nb.status.state // "none") | \(if $nb != null then ((ageHours($nb.metadata.creationTimestamp) // null) as $h | if $h == null then "—" else (($h|round)|tostring) + "h" end) else "—" end) | \(fmtBytes($bv.dataStored | tonumber? // null)) | \(if $isProt and ($nb == null or $nb.status.state != "Completed") then "**NO RESTORABLE BACKUP**" else "" end) |"
  ] | join("\n") ) + "\n" +
  "\n## Node / Disk Pressure\n\n" +
  "| Node | Disk | Available | Maximum | Scheduled | Used % | Over-provisioning % |\n" +
  "|---|---|---|---|---|---|---|\n" +
  ( [ (($curArr[0]).longhorn_nodes.items // [])[] as $n
	| ($n.status.diskStatus // {}) | to_entries[] as $d
	| ($d.value.storageAvailable) as $avail
	| ($d.value.storageMaximum) as $max
	| ($d.value.storageScheduled) as $sched
	| "| \($n.metadata.name) | \($d.key) | \(fmtBytes($avail)) | \(fmtBytes($max)) | \(fmtBytes($sched)) | \(pctStr($max - $avail; $max)) | \(pctStr($sched; $max)) |"
  ] | join("\n") ) + "\n" +
  "\n## Trend\n\n" +
  ( if ($prevArr[0]) == null then "*No previous snapshot — trend available from next run.*\n"
    else
	"Since previous snapshot (\($daysSincePrev | . * 100 | round / 100) days ago, collected \(($prevArr[0]).collected_at)):\n\n" +
	"| Volume | Then | Now | Δ | Growth/day | Days to full (projected) |\n" +
	"|---|---|---|---|---|---|\n" +
	( [ $vols[] |
		. as $v
		| volLabel($v) as $label
		| ($stats[$label].used) as $used
		| ($stats[$label].cap // ($v.spec.size | tonumber? // 0)) as $cap
		| ($prevStats[$label]) as $prevUsed
		| if $prevUsed == null then "| \($label) | — | \(fmtBytes($used)) | new | — | — |"
		  else
			(($used // 0) - $prevUsed) as $delta
			| (if $daysSincePrev > 0 then $delta / $daysSincePrev else null end) as $perDay
			| (if $perDay != null and $perDay > 0 and $cap != null then (($cap - $used) / $perDay | round) else null end) as $daysToFull
			| "| \($label) | \(fmtBytes($prevUsed)) | \(fmtBytes($used)) | \(if $delta >= 0 then "+" else "" end)\(fmtBytes($delta)) | \(if $perDay == null then "—" else (if $perDay >= 0 then "+" else "" end) + fmtBytes($perDay) + "/day" end) | \(if $daysToFull == null then "—" elif $daysToFull <= $th.projectDaysWarn then "**\($daysToFull)**" else ($daysToFull|tostring) end) |"
		  end
	] | join("\n") ) + "\n"
    end )
