#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/bootstrap.yaml
SEALED=templates/sealed-bootstrap-secret.yaml

mkdir -p secrets
chmod go-rwx secrets

if [ ! -f "$PLAIN" ]; then
  EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-}"
  [ -n "$EMAIL" ] || read -r -p "Enter Authentik admin (akadmin) email: " EMAIL

  if [ -z "$EMAIL" ]; then
    echo "Error: Authentik admin email must be provided"
    exit 1
  fi

  # AUTHENTIK_BOOTSTRAP_* only apply to the first migrate against an empty DB, so a
  # fresh cluster comes up with a usable akadmin instead of the initial-setup flow.
  # LDAP_BIND_KEY is deliberately unprefixed - authentik parses AUTHENTIK_* as config
  # paths. The access blueprint reads it via !Env. Split out of generate-secret.sh so
  # these can be (re)generated independently of the Postgres password / Django secret
  # key, which must never be re-rolled on a running install.
  kubectl create secret generic authentik-bootstrap \
    --namespace authentik \
    --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$(openssl rand -base64 32)" \
    --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$(openssl rand -hex 32)" \
    --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="$EMAIL" \
    --from-literal=LDAP_BIND_KEY="$(openssl rand -hex 32)" \
    --dry-run=client -o yaml > "$PLAIN"
  chmod go-rwx "$PLAIN"
  unset EMAIL
fi

seal_if_needed "$PLAIN" "$SEALED"
