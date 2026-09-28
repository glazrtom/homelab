#! /bin/bash
# Two Secrets share one plaintext file, same pattern as rallly/generate-secret.sh:
# ntfy's own declarative users/tokens (templates/_env.tpl's NTFY_AUTH_USERS/
# NTFY_AUTH_TOKENS), and Alertmanager's bearer token for the ntfy webhook -
# reflected into monitoring/ the same way gatus/generate-secret.sh reflects its
# heartbeat token into longhorn-system.
#
# Adding a token for another service that wants to push through ntfy: add a
# resolve/NTFY_AUTH_ACCESS line here for that service's user, mint it a token the
# same way AM_TOKEN is minted below, and reflect its Secret into that service's
# namespace.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

# bcrypt hash for NTFY_AUTH_USERS's <user>:<hash>:<role> lines - ntfy accepts
# $2a$/$2b$/$2y$ interchangeably, but normalize to $2a$ since that's what its own
# docs show. macOS ships httpd's htpasswd (Apache) which this shells out to.
bhash() { htpasswd -bnBC 10 "" "$1" | tr -d ':\n' | sed 's/^\$2y/\$2a/'; }

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml

secret_source ntfy ntfy-auth
resolve ADMIN_USER --static admin
resolve ADMIN_PASSWORD --gen 'rand_alnum 32'
# Never used to log in - a bearer token needs an owning user (NTFY_AUTH_TOKENS
# below), and ntfy has no "service account with no password" concept.
resolve AM_PASSWORD --unsafe-force --gen 'rand_alnum 32'
resolve NTFY_AUTH_USERS --gen 'printf "%s:%s:admin,alertmanager:%s:user" "$ADMIN_USER" "$(bhash "$ADMIN_PASSWORD")" "$(bhash "$AM_PASSWORD")"'
resolve AM_TOKEN --unsafe-force --gen 'printf "tk_%s" "$(openssl rand -base64 64 | LC_ALL=C tr -dc a-z0-9 | head -c 29)"'
resolve NTFY_AUTH_TOKENS --gen 'printf "alertmanager:%s:alertmanager" "$AM_TOKEN"'
secret_literal_args
kubectl create secret generic ntfy-auth --namespace ntfy \
  "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml > "$PLAIN"

secret_source ntfy ntfy-alertmanager-token
resolve TOKEN --env AM_TOKEN
{
  echo "---"
  kubectl create secret generic ntfy-alertmanager-token \
    --namespace ntfy \
    --from-literal=TOKEN="$TOKEN" \
    --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
     $(reflector_annotations "monitoring") \
     --output yaml
} >> "$PLAIN"

secret_finish
