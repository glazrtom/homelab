#! /bin/bash
# Deploy-gate poller for the GitHub Actions "Deploy" workflow (see deploy.yml).
#
# Every push to master is auto-synced by ArgoCD within minutes; this script is the only
# automated signal that a push actually deployed cleanly. It hard-refreshes the app-of-apps
# Applications and every child Application, then polls the ArgoCD REST API (over the
# ungated argo-ci host, behind Cloudflare Access) until each is Synced/Healthy at the
# pushed commit, or the timeout expires.
#
# Usage: scripts/argocd-wait.sh <revision-sha>

set -euo pipefail

REVISION="${1:?usage: argocd-wait.sh <revision-sha>}"

ARGOCD_SERVER="${ARGOCD_SERVER:-argo-ci.glazrtom.cz}"
ARGOCD_AUTH_TOKEN="${ARGOCD_AUTH_TOKEN:?ARGOCD_AUTH_TOKEN is required}"
CF_ACCESS_CLIENT_ID="${CF_ACCESS_CLIENT_ID:?CF_ACCESS_CLIENT_ID is required}"
CF_ACCESS_CLIENT_SECRET="${CF_ACCESS_CLIENT_SECRET:?CF_ACCESS_CLIENT_SECRET is required}"
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-https://github.com/glazrtom/homelab.git}"
ARGOCD_WAIT_TIMEOUT="${ARGOCD_WAIT_TIMEOUT:-60}"
ARGOCD_POLL_INTERVAL="${ARGOCD_POLL_INTERVAL:-10}"

API="https://${ARGOCD_SERVER}/api/v1"

# api_call <path> -> prints "<body>\n<code>" on stdout. Never fails on its own -
# callers decide what a given status code means (fatal vs. "app is gone"). Deliberately
# does not set a variable for the code: command substitution runs in a subshell, so an
# assignment made inside this function would never be visible to the caller.
api_call() {
  curl --silent --show-error --retry 3 --retry-delay 2 -w '\n%{http_code}' \
    -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    "${API}$1"
}

# api_get <path> -> body on stdout; fails loudly (prints path/code/body) on non-200.
# Used where a failure is genuinely fatal: enumerating apps, refreshing/checking core+apps.
api_get() {
  local out code body
  out="$(api_call "$1")"
  code="$(tail -n1 <<<"$out")"
  body="$(sed '$d' <<<"$out")"
  if [ "$code" != "200" ]; then
    echo "FATAL: GET $1 -> HTTP ${code}" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s\n' "$body"
}

# api_get_soft <path> -> body on stdout, returns 1 quietly on 403/404 (app gone or
# unreadable - the shape ArgoCD returns for a name that no longer exists), still fails
# loudly on anything else. Used for every per-child call, since children come and go as
# the media ApplicationSet regenerates its instances mid-run.
api_get_soft() {
  local out code body
  out="$(api_call "$1")"
  code="$(tail -n1 <<<"$out")"
  body="$(sed '$d' <<<"$out")"
  case "$code" in
    200) printf '%s\n' "$body"; return 0 ;;
    403|404) return 1 ;;
    *)
      echo "FATAL: GET $1 -> HTTP ${code}" >&2
      echo "$body" >&2
      return 1
      ;;
  esac
}

refresh() {
  api_get "/applications/$1?refresh=hard" >/dev/null
}

refresh_soft() {
  api_get_soft "/applications/$1?refresh=hard" >/dev/null
}

# app_ok <name> -> 0 if Synced+Healthy (and, for apps tracking our repo, at REVISION).
# Uses api_get_soft: an app that vanished between enumeration and check just counts as
# not-ok for this iteration, rather than aborting the whole run.
app_ok() {
  local name="$1" json sync health repo revision phase ok
  json="$(api_get_soft "/applications/${name}")" || {
    printf '%-20s (gone)\n' "$name" >&2
    return 1
  }
  sync="$(jq -r '.status.sync.status' <<<"$json")"
  health="$(jq -r '.status.health.status' <<<"$json")"
  repo="$(jq -r '(.spec.source.repoURL // (.spec.sources[0].repoURL))' <<<"$json")"
  revision="$(jq -r '.status.sync.revision' <<<"$json")"
  # sync/health go green as soon as resources reconcile, but the sync *operation*
  # (PostSync hooks included - e.g. authentik's blueprint-apply Job) can still be
  # running underneath that. Only gate on an operation still in flight - a stale
  # Failed/Error from an older operation must not permanently fail this check, since
  # real problems already surface through sync/health above.
  phase="$(jq -r '.status.operationState.phase // ""' <<<"$json")"

  ok=1
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && ok=0
  if [ "$ok" -eq 0 ] && [ "$repo" = "$ARGOCD_REPO_URL" ] && [ "$revision" != "$REVISION" ]; then
    ok=1
  fi
  case "$phase" in
    Running | Terminating) ok=1 ;;
  esac

  printf '%-20s sync=%-10s health=%-10s phase=%-11s revision=%s\n' "$name" "$sync" "$health" "$phase" "$revision" >&2
  return "$ok"
}

dump_failure() {
  local name="$1" json
  json="$(api_get_soft "/applications/${name}")" || { echo "--- ${name}: gone ---" >&2; return; }
  echo "--- ${name}: conditions ---" >&2
  jq -r '.status.conditions // [] | .[] | "\(.type): \(.message)"' <<<"$json" >&2
  echo "--- ${name}: operation state ---" >&2
  jq -r '.status.operationState.message // "(none)"' <<<"$json" >&2
  echo "--- ${name}: non-Synced/Healthy resources ---" >&2
  jq -r '.status.resources // [] | .[] | select(.status != "Synced" or (.health.status // "Healthy") != "Healthy") | "\(.kind)/\(.name) sync=\(.status) health=\(.health.status // "Healthy")"' <<<"$json" >&2
}

# wait_for <names...> -> fixed-list wait, used for the app-of-apps (core, apps) whose
# names are known up front and must not disappear.
wait_for() {
  local names=("$@") deadline elapsed all_ok pending
  deadline=$((SECONDS + ARGOCD_WAIT_TIMEOUT))

  for n in "${names[@]}"; do refresh "$n"; done

  while :; do
    all_ok=1
    pending=()
    echo "--- polling (elapsed ${elapsed:-0}s) ---" >&2
    for n in "${names[@]}"; do
      if ! app_ok "$n"; then
        all_ok=0
        pending+=("$n")
      fi
    done

    if [ "$all_ok" -eq 1 ]; then
      echo "all of: ${names[*]} are Synced/Healthy" >&2
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "TIMEOUT waiting for: ${pending[*]}" >&2
      for n in "${pending[@]}"; do dump_failure "$n"; done
      return 1
    fi

    sleep "$ARGOCD_POLL_INTERVAL"
  done
}

# wait_for_children -> re-enumerates children every iteration instead of freezing the
# list up front, since ApplicationSets (media/) can add/remove instances mid-run. Only
# passes once the enumerated set is non-empty, all-green, AND identical to the previous
# iteration's set - guards against greenlighting on a snapshot taken just before an
# ApplicationSet swaps its instances.
wait_for_children() {
  local deadline prev_set="" refreshed=":" pending start

  start="$SECONDS"
  deadline=$((SECONDS + ARGOCD_WAIT_TIMEOUT))

  while :; do
    local names current_set all_ok
    mapfile -t names < <(api_get "/applications" | jq -r '.items[].metadata.name | select(. != "core" and . != "apps")')
    current_set="$(printf '%s\n' "${names[@]}" | sort)"

    for n in "${names[@]}"; do
      case "$refreshed" in
        *":$n:"*) ;;
        *) refresh_soft "$n" || true; refreshed="${refreshed}${n}:" ;;
      esac
    done

    echo "children: ${names[*]}" >&2
    echo "--- polling (elapsed $((SECONDS - start))s) ---" >&2

    all_ok=1
    pending=()
    for n in "${names[@]}"; do
      if ! app_ok "$n"; then
        all_ok=0
        pending+=("$n")
      fi
    done

    if [ "$all_ok" -eq 1 ] && [ -n "$current_set" ] && [ "$current_set" = "$prev_set" ]; then
      echo "all of: ${names[*]} are Synced/Healthy and stable" >&2
      return 0
    fi

    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "TIMEOUT waiting for: ${pending[*]}" >&2
      for n in "${pending[@]}"; do dump_failure "$n"; done
      return 1
    fi

    prev_set="$current_set"
    sleep "$ARGOCD_POLL_INTERVAL"
  done
}

echo "== refreshing app-of-apps ==" >&2
wait_for core apps

echo "== waiting on children (re-enumerated each poll) ==" >&2
wait_for_children
