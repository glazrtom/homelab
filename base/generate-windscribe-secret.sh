#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/windscribe.yaml
SEALED=windscribe-sealed.yaml

mkdir -p secrets
chmod go-rwx secrets

if [ ! -f "$PLAIN" ]; then
  USERNAME="${WINDSCRIBE_USERNAME:-}"
  PASSWORD="${WINDSCRIBE_PASSWORD:-}"

  [ -n "$USERNAME" ] || read -r -p "Enter Windscribe username: " USERNAME
  [ -n "$PASSWORD" ] || read -r -s -p "Enter Windscribe password: " PASSWORD
  echo

  if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Error: username and password must be provided"
    exit 1
  fi

  kubectl create secret generic windscribe-auth \
    --namespace default \
    --from-literal=username="$USERNAME" \
    --from-literal=password="$PASSWORD" \
    --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
     reflector.v1.k8s.emberstack.com/reflection-allowed=true \
     reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=media,transmission \
     reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
     reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=media,transmission \
     --output yaml > "$PLAIN"

  chmod go-rwx "$PLAIN"
  unset USERNAME PASSWORD
fi

seal_if_needed "$PLAIN" "$SEALED"
