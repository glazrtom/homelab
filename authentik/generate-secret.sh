#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/secret.yaml
SEALED=templates/sealed-secret.yaml

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
  # paths. The access blueprint reads it via !Env.
  kubectl create secret generic authentik-secrets \
    --namespace authentik \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$(openssl rand -base64 32)" \
    --from-literal=AUTHENTIK_SECRET_KEY="$(openssl rand -base64 32)" \
    --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="$(openssl rand -base64 32)" \
    --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="$(openssl rand -hex 32)" \
    --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="$EMAIL" \
    --from-literal=LDAP_BIND_KEY="$(openssl rand -hex 32)" \
    --dry-run=client -o yaml > "$PLAIN"
  chmod go-rwx "$PLAIN"
  unset EMAIL
fi

seal_if_needed "$PLAIN" "$SEALED"
