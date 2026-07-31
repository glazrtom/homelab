#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/secret.yaml
SEALED=templates/sealed-secret.yaml

mkdir -p secrets
chmod go-rwx secrets

if [ ! -f "$PLAIN" ]; then
  kubectl create secret generic authentik-secrets \
    --namespace authentik \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$(openssl rand -base64 32)" \
    --from-literal=AUTHENTIK_SECRET_KEY="$(openssl rand -base64 32)" \
    --dry-run=client -o yaml > "$PLAIN"
  chmod go-rwx "$PLAIN"
fi

seal_if_needed "$PLAIN" "$SEALED"
