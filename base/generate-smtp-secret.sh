#! /bin/bash
# Cluster-wide SMTP credential, reflected by reflector into every namespace that needs
# to send mail (rallly, gatus). Idempotent like the other generate-*secret*.sh scripts:
# reuse the git-ignored plaintext when present; otherwise fall back to the value already
# live in the rallly Secret (pre-migration source of truth), then prompt.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/smtp.yaml
SEALED=smtp-sealed.yaml

mkdir -p secrets
chmod go-rwx secrets

# Echo the base64-decoded value of KEY from the live NAMESPACE/SECRET, or nothing.
_live() {
  local namespace="$1" secret="$2" key="$3" b64
  b64="$(kubectl -n "$namespace" get secret "$secret" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
  [ -n "$b64" ] && printf '%s' "$b64" | base64 -d || true
}

if [ ! -f "$PLAIN" ]; then
  PASSWORD="${SMTP_PWD:-}"
  [ -n "$PASSWORD" ] || PASSWORD="$(_live rallly rallly SMTP_PWD)"
  if [ -z "$PASSWORD" ]; then
    read -r -s -p "Enter SMTP password (Gmail app password): " PASSWORD
    echo
  fi

  if [ -z "$PASSWORD" ]; then
    echo "Error: password must be provided"
    exit 1
  fi

  kubectl create secret generic smtp-credentials \
    --namespace default \
    --from-literal=SMTP_PWD="$PASSWORD" \
    --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
     reflector.v1.k8s.emberstack.com/reflection-allowed=true \
     reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=rallly,gatus \
     reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
     reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=rallly,gatus \
     --output yaml > "$PLAIN"

  chmod go-rwx "$PLAIN"
  unset PASSWORD
fi

seal_if_needed "$PLAIN" "$SEALED"
