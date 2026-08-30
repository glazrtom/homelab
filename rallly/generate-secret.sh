#! /bin/bash
# Rallly needs its Postgres, Garage and app credentials supplied as pre-existing
# Secrets: the chart's own generation relies on Helm `lookup`, which does not work
# under ArgoCD (`helm template`), so it would mint fresh random credentials on every
# render and break the already-initialised Postgres/Garage data. See the chart README.
#
# Three Secrets share one plaintext file. Each key backfills independently (local
# plaintext, then the live cluster, then a generator) via scripts/secretlib.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml

secret_source rallly rallly-postgresql
resolve POSTGRES_USER --static rallly
resolve POSTGRES_PASSWORD --gen 'rand_alnum 32'
resolve POSTGRES_DB --static rallly
secret_literal_args
kubectl create secret generic rallly-postgresql --namespace rallly \
  "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml > "$PLAIN"

secret_source rallly rallly-garage
resolve GARAGE_RPC_SECRET --gen 'rand_hex 64'
resolve GARAGE_DEFAULT_ACCESS_KEY --gen 'rand_alnum 24'
resolve GARAGE_DEFAULT_SECRET_KEY --gen 'rand_alnum 48'
secret_literal_args
{
  echo "---"
  kubectl create secret generic rallly-garage --namespace rallly \
    "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml
} >> "$PLAIN"

secret_source rallly rallly
resolve SECRET_PASSWORD --gen 'rand_alnum 32'
resolve CRON_SECRET --gen 'rand_alnum 32'
secret_literal_args
{
  echo "---"
  kubectl create secret generic rallly --namespace rallly \
    "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml
} >> "$PLAIN"

secret_finish
