#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

PLAIN=secrets/b2.yaml
SEALED=templates/sealed-b2.yaml

mkdir -p secrets
chmod go-rwx secrets

if [ ! -f "$PLAIN" ]; then
  KEY_ID="${B2_KEY_ID:-}"
  APP_KEY="${B2_APP_KEY:-}"
  ENDPOINT="${B2_ENDPOINT:-}"

  [ -n "$KEY_ID" ] || read -r -p "Enter Backblaze B2 keyID: " KEY_ID
  [ -n "$APP_KEY" ] || read -r -s -p "Enter Backblaze B2 applicationKey: " APP_KEY
  echo
  [ -n "$ENDPOINT" ] || read -r -p "Enter Backblaze B2 S3 endpoint URL (e.g. https://s3.eu-central-003.backblazeb2.com): " ENDPOINT

  if [ -z "$KEY_ID" ] || [ -z "$APP_KEY" ] || [ -z "$ENDPOINT" ]; then
    echo "Error: keyID, applicationKey and endpoint must be provided"
    exit 1
  fi

  kubectl create secret generic longhorn-b2-credentials \
    --namespace longhorn-system \
    --from-literal=AWS_ACCESS_KEY_ID="$KEY_ID" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$APP_KEY" \
    --from-literal=AWS_ENDPOINTS="$ENDPOINT" \
    --from-literal=VIRTUAL_HOSTED_STYLE="true" \
    --dry-run=client -o yaml > "$PLAIN"

  chmod go-rwx "$PLAIN"
  unset KEY_ID APP_KEY ENDPOINT
fi

seal_if_needed "$PLAIN" "$SEALED"
