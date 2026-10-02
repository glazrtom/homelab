#! /bin/bash
# ExcaliDash needs its JWT/CSRF/API-key-pepper secrets and the bundled Postgres password supplied as a pre-existing Secret:
# the chart never generates them (lookup/random values would rotate under ArgoCD).
# API_KEY_HASH_PEPPER must never change once API keys exist - each key backfills from
# local plaintext, then the live cluster, so a re-run never re-rolls an existing value.
# The OIDC client is public (PKCE), so there is no OIDC_CLIENT_SECRET to seal.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml

secret_source excalidash excalidash-secrets
resolve JWT_SECRET --gen 'rand_alnum 64'
resolve CSRF_SECRET --gen 'rand_alnum 64'
resolve API_KEY_HASH_PEPPER --gen 'rand_alnum 64'
resolve POSTGRES_PASSWORD --gen 'rand_alnum 32' --unsafe-force \
  --follow-up "Postgres reads POSTGRES_PASSWORD only at initdb; also ALTER USER excalidash PASSWORD in the pod"
secret_literal_args
kubectl create secret generic excalidash-secrets --namespace excalidash \
  "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml > "$PLAIN"

secret_finish
