#! /bin/bash
# One Secret, dawarich-secrets, read by web, sidekiq, postgis and redis (see
# templates/_env.tpl). Each key backfills independently (local plaintext, then the live
# cluster, then a generator) via scripts/secretlib.sh.
#
# SECRET_KEY_BASE signs sessions; the database and redis passwords are baked into the
# existing volumes on first start, so --force skips them - only `--force-key NAME`
# rolls one. OIDC_CLIENT_SECRET is not here: authentik/generate-secret.sh owns it and
# reflector copies it in as dawarich-oidc-client. SMTP_PASSWORD is human-supplied: this
# app's own Gmail app password (see the smtp skill).
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml

secret_source dawarich dawarich-secrets
resolve SECRET_KEY_BASE --gen 'rand_hex 64' --unsafe-force \
  --follow-up 'invalidates every Dawarich session'
resolve DATABASE_USERNAME --static dawarich
resolve DATABASE_PASSWORD --gen 'rand_alnum 32' --unsafe-force \
  --follow-up 'ALTER USER the live Postgres role to match, then restart dawarich'
resolve REDIS_PASSWORD --gen 'rand_hex 32' --unsafe-force \
  --follow-up 'restart redis, web and sidekiq together'
resolve SMTP_PASSWORD --prompt 'Dawarich Gmail app password' --unsafe-force \
  --follow-up 'revoke the old app password in the Google account'
secret_literal_args
kubectl create secret generic dawarich-secrets --namespace dawarich \
  "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml > "$PLAIN"

secret_finish
