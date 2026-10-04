#! /bin/bash
# jellyfin-exporter's API key. It only exists inside Jellyfin, so it can't be generated:
# create one first (Dashboard > API Keys > +, name it "prometheus") and paste it when
# prompted. --unsafe-force keeps `--force` from re-prompting for it.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml
secret_source jellyfin jellyfin-exporter

resolve JELLYFIN_TOKEN --prompt 'Enter the Jellyfin API key for the exporter' --unsafe-force

secret_literal_args
kubectl create secret generic jellyfin-exporter \
  --namespace jellyfin \
  "${SECRET_LITERAL_ARGS[@]}" \
  --dry-run=client -o yaml > "$PLAIN"

secret_finish
