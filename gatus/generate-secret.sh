#! /bin/bash
# Bearer token Gatus's external endpoints expect on incoming heartbeat pushes - the
# push/heartbeat-monitor equivalent of Uptime Kuma's push URL. Reflected into every
# namespace whose own CronJob/script needs to report in (currently just
# longhorn-system, for the backup report CronJob - see
# longhorn/templates/backup-report-cronjob.yaml).
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/heartbeat-token.yaml templates/sealed-heartbeat-token.yaml
secret_source gatus gatus-heartbeat-token

resolve HEARTBEAT_TOKEN --gen 'rand_hex 20'

kubectl create secret generic gatus-heartbeat-token \
  --namespace gatus \
  --from-literal=HEARTBEAT_TOKEN="$HEARTBEAT_TOKEN" \
  --dry-run=client -o yaml \
| kubectl annotate --local -f - \
   $(reflector_annotations "longhorn-system") \
   --output yaml > "$PLAIN"

secret_finish
