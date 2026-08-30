#! /bin/bash
# Bearer token Gatus's external endpoints expect on incoming heartbeat pushes - the
# push/heartbeat-monitor equivalent of Uptime Kuma's push URL. Reflected into every
# namespace whose own CronJob/script needs to report in (currently just
# longhorn-system, for the backup report CronJob - see
# longhorn/templates/backup-report-cronjob.yaml).
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

NAMESPACE=gatus
PLAIN=secrets/heartbeat-token.yaml
SEALED=templates/sealed-heartbeat-token.yaml

mkdir -p secrets
chmod go-rwx secrets

_live() {
  local b64
  b64="$(kubectl -n "$NAMESPACE" get secret gatus-heartbeat-token -o "jsonpath={.data.HEARTBEAT_TOKEN}" 2>/dev/null || true)"
  [ -n "$b64" ] && printf '%s' "$b64" | base64 -d || true
}

_rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

if [ ! -f "$PLAIN" ]; then
  TOKEN="$(_live)"
  [ -n "$TOKEN" ] || TOKEN="$(_rand 40)"

  kubectl create secret generic gatus-heartbeat-token \
    --namespace "$NAMESPACE" \
    --from-literal=HEARTBEAT_TOKEN="$TOKEN" \
    --dry-run=client -o yaml \
  | kubectl annotate --local -f - \
     reflector.v1.k8s.emberstack.com/reflection-allowed=true \
     reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=longhorn-system \
     reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true \
     reflector.v1.k8s.emberstack.com/reflection-auto-namespaces=longhorn-system \
     --output yaml > "$PLAIN"

  chmod go-rwx "$PLAIN"
  unset TOKEN
fi

seal_if_needed "$PLAIN" "$SEALED"
