#! /bin/bash
# Cluster-wide SMTP credential, reflected by reflector into every namespace that
# needs to send mail (rallly, gatus). Falls back to the value already live in the
# rallly Secret (pre-migration source of truth) before prompting.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/smtp.yaml smtp-sealed.yaml
secret_source default smtp-credentials

resolve SMTP_PWD --prompt 'Enter SMTP password (Gmail app password)' --from rallly/rallly

kubectl create secret generic smtp-credentials \
  --namespace default \
  --from-literal=SMTP_PWD="$SMTP_PWD" \
  --dry-run=client -o yaml \
| kubectl annotate --local -f - \
   $(reflector_annotations "rallly,gatus") \
   --output yaml > "$PLAIN"

secret_finish
