#! /bin/bash
# Rallly needs its Postgres, Garage and app credentials supplied as pre-existing
# Secrets: the chart's own generation relies on Helm `lookup`, which does not work
# under ArgoCD (`helm template`), so it would mint fresh random credentials on every
# render and break the already-initialised Postgres/Garage data. See the chart README.
#
# Idempotent, like the other generate-*secret*.sh scripts: reuse the git-ignored
# plaintext when present; otherwise capture the values already live in the cluster
# (so an existing install keeps working); otherwise generate fresh ones (new cluster).
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

NAMESPACE=rallly
PLAIN=secrets/secret.yaml
SEALED=templates/sealed-secret.yaml

mkdir -p secrets
chmod go-rwx secrets

# Echo the base64-decoded value of KEY from the live NAMESPACE/SECRET, or nothing.
_live() {
  local secret="$1" key="$2" b64
  b64="$(kubectl -n "$NAMESPACE" get secret "$secret" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
  [ -n "$b64" ] && printf '%s' "$b64" | base64 -d || true
}

# Resolve a value: live cluster value if present, else a freshly generated one.
_resolve() {
  local secret="$1" key="$2" gen="$3" v
  v="$(_live "$secret" "$key")"
  [ -n "$v" ] || v="$gen"
  printf '%s' "$v"
}

_rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }
_hex()  { LC_ALL=C tr -dc 'a-f0-9'    < /dev/urandom | head -c "$1"; }

if [ ! -f "$PLAIN" ]; then
  PG_USER="$(_resolve rallly-postgresql POSTGRES_USER rallly)"
  PG_PASS="$(_resolve rallly-postgresql POSTGRES_PASSWORD "$(_rand 32)")"
  PG_DB="$(_resolve rallly-postgresql POSTGRES_DB rallly)"

  GARAGE_RPC="$(_resolve rallly-garage GARAGE_RPC_SECRET "$(_hex 64)")"
  GARAGE_AK="$(_resolve rallly-garage GARAGE_DEFAULT_ACCESS_KEY "$(_rand 24)")"
  GARAGE_SK="$(_resolve rallly-garage GARAGE_DEFAULT_SECRET_KEY "$(_rand 48)")"

  APP_SECRET="$(_resolve rallly SECRET_PASSWORD "$(_rand 32)")"
  CRON_SECRET="$(_resolve rallly CRON_SECRET "$(_rand 32)")"

  {
    cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rallly-postgresql
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  POSTGRES_USER: "${PG_USER}"
  POSTGRES_PASSWORD: "${PG_PASS}"
  POSTGRES_DB: "${PG_DB}"
---
apiVersion: v1
kind: Secret
metadata:
  name: rallly-garage
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  GARAGE_RPC_SECRET: "${GARAGE_RPC}"
  GARAGE_DEFAULT_ACCESS_KEY: "${GARAGE_AK}"
  GARAGE_DEFAULT_SECRET_KEY: "${GARAGE_SK}"
---
apiVersion: v1
kind: Secret
metadata:
  name: rallly
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  SECRET_PASSWORD: "${APP_SECRET}"
  CRON_SECRET: "${CRON_SECRET}"
EOF
  } > "$PLAIN"

  chmod go-rwx "$PLAIN"
  unset PG_PASS GARAGE_RPC GARAGE_AK GARAGE_SK APP_SECRET CRON_SECRET
fi

seal_if_needed "$PLAIN" "$SEALED"
