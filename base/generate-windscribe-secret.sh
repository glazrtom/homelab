#! /bin/bash
# Windscribe VPN credential, reflected by reflector into media (prowlarr's gluetun
# sidecar) and transmission - neither chart owns this secret, they reference
# windscribe-auth by name.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/windscribe.yaml windscribe-sealed.yaml
secret_source default windscribe-auth

resolve username --prompt 'Enter Windscribe username' --echo --env WINDSCRIBE_USERNAME
resolve password --prompt 'Enter Windscribe password' --env WINDSCRIBE_PASSWORD

kubectl create secret generic windscribe-auth \
  --namespace default \
  --from-literal=username="$username" \
  --from-literal=password="$password" \
  --dry-run=client -o yaml \
| kubectl annotate --local -f - \
   $(reflector_annotations "media,transmission") \
   --output yaml > "$PLAIN"

secret_finish
