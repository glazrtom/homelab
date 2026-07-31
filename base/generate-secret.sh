#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/github-credentials.yaml
SEALED=github-credentials-sealed.yaml

mkdir -p secrets
chmod go-rwx secrets

if [ ! -f "$PLAIN" ]; then
  USERNAME="${GHCR_USERNAME:-}"
  TOKEN="${GHCR_TOKEN:-}"
  EMAIL="${GHCR_EMAIL:-}"

  [ -n "$USERNAME" ] || read -r -p "Enter GitHub username: " USERNAME
  [ -n "$TOKEN" ] || read -r -s -p "Enter GitHub PAT: " TOKEN
  echo
  [ -n "$EMAIL" ] || read -r -p "Enter GitHub email: " EMAIL

  if [ -z "$USERNAME" ] || [ -z "$TOKEN" ] || [ -z "$EMAIL" ]; then
    echo "Error: username, token and email must be provided"
    exit 1
  fi

  kubectl create secret docker-registry ghcr-credentials \
    --docker-server=ghcr.io \
    --docker-username="$USERNAME" \
    --docker-password="$TOKEN" \
    --docker-email="$EMAIL" \
    --namespace default \
    --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
     reflector.v1.k8s.emberstack.com/reflection-allowed=true \
     --output yaml > "$PLAIN"

  chmod go-rwx "$PLAIN"
  unset USERNAME TOKEN EMAIL
fi

seal_if_needed "$PLAIN" "$SEALED"
