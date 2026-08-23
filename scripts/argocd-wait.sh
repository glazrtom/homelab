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

api_get() {
  curl --fail-with-body --silent --show-error --retry 3 --retry-delay 2 \
    -H "Authorization: Bearer ${ARGOCD_AUTH_TOKEN}" \
    -H "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}" \
    -H "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}" \
    "${API}$1"
}

refresh() {
  api_get "/applications/$1?refresh=hard" >/dev/null
}

# app_ok <name> -> 0 if Synced+Healthy (and, for apps tracking our repo, at REVISION)
app_ok() {
  local name="$1" json sync health repo revision ok
  json="$(api_get "/applications/${name}")"
  sync="$(jq -r '.status.sync.status' <<<"$json")"
  health="$(jq -r '.status.health.status' <<<"$json")"
  repo="$(jq -r '(.spec.source.repoURL // (.spec.sources[0].repoURL))' <<<"$json")"
  revision="$(jq -r '.status.sync.revision' <<<"$json")"

  ok=1
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && ok=0
  if [ "$ok" -eq 0 ] && [ "$repo" = "$ARGOCD_REPO_URL" ] && [ "$revision" != "$REVISION" ]; then
    ok=1
  fi

  printf '%-20s sync=%-10s health=%-10s revision=%s\n' "$name" "$sync" "$health" "$revision" >&2
  return "$ok"
}

dump_failure() {
  local name="$1" json
  json="$(api_get "/applications/${name}")"
  echo "--- ${name}: conditions ---" >&2
  jq -r '.status.conditions // [] | .[] | "\(.type): \(.message)"' <<<"$json" >&2
  echo "--- ${name}: operation state ---" >&2
  jq -r '.status.operationState.message // "(none)"' <<<"$json" >&2
  echo "--- ${name}: non-Synced/Healthy resources ---" >&2
  jq -r '.status.resources // [] | .[] | select(.status != "Synced" or (.health.status // "Healthy") != "Healthy") | "\(.kind)/\(.name) sync=\(.status) health=\(.health.status // "Healthy")"' <<<"$json" >&2
}

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

echo "== refreshing app-of-apps ==" >&2
wait_for core apps

echo "== enumerating child applications ==" >&2
mapfile -t children < <(api_get "/applications" | jq -r '.items[].metadata.name | select(. != "core" and . != "apps")')
echo "children: ${children[*]}" >&2

echo "== waiting on children ==" >&2
wait_for "${children[@]}"
