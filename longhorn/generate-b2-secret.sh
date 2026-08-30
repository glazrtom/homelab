#! /bin/bash
# Backblaze B2 credentials for Longhorn's backup target.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/b2.yaml templates/sealed-b2.yaml
secret_source longhorn-system longhorn-b2-credentials

resolve AWS_ACCESS_KEY_ID --prompt 'Enter Backblaze B2 keyID' --echo --env B2_KEY_ID
resolve AWS_SECRET_ACCESS_KEY --prompt 'Enter Backblaze B2 applicationKey' --env B2_APP_KEY
resolve AWS_ENDPOINTS \
  --prompt 'Enter Backblaze B2 S3 endpoint URL (e.g. https://s3.eu-central-003.backblazeb2.com)' \
  --echo --env B2_ENDPOINT
resolve VIRTUAL_HOSTED_STYLE --static true

secret_literal_args
kubectl create secret generic longhorn-b2-credentials \
  --namespace longhorn-system \
  "${SECRET_LITERAL_ARGS[@]}" \
  --dry-run=client -o yaml > "$PLAIN"

secret_finish
