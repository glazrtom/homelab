#! /bin/bash
# GHCR pull secret, reflected by reflector (emberstack) into other namespaces.
# The live/local Secret stores a single dockerconfigjson blob rather than the three
# inputs directly, so recovery pulls them back out of that JSON with jq before
# falling through to a prompt.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/github-credentials.yaml github-credentials-sealed.yaml
secret_source default ghcr-credentials

_ghcr_field() {
  local field="$1" blob
  blob="$(local_value ghcr-credentials .dockerconfigjson)"
  [ -n "$blob" ] || blob="$(live_value default ghcr-credentials .dockerconfigjson)"
  [ -n "$blob" ] || return 0
  printf '%s' "$blob" | jq -r ".auths[\"ghcr.io\"].${field} // empty"
}

: "${GHCR_USERNAME:=$(_ghcr_field username)}"
: "${GHCR_TOKEN:=$(_ghcr_field password)}"
: "${GHCR_EMAIL:=$(_ghcr_field email)}"

resolve GHCR_USERNAME --prompt 'Enter GitHub username' --echo
resolve GHCR_TOKEN --prompt 'Enter GitHub PAT'
resolve GHCR_EMAIL --prompt 'Enter GitHub email' --echo

kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GHCR_TOKEN" \
  --docker-email="$GHCR_EMAIL" \
  --namespace default \
  --dry-run=client -o yaml \
| kubectl annotate --local -f - \
   $(reflector_annotations "") \
   --output yaml > "$PLAIN"

secret_finish
