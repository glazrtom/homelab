#! /bin/bash
# Two Secrets share one plaintext file, same pattern as rallly/generate-secret.sh:
# Grafana's admin login, and the healthchecks.io ping key for the dead-man-switch
# DaemonSet (templates/heartbeat-daemonset.yaml, disabled by default in
# values.yaml until this key is sealed - there is no free/generatable value, it
# has to come from a real healthchecks.io account).
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
secret_init secrets/secret.yaml templates/sealed-secret.yaml

secret_source monitoring monitoring-grafana-admin
resolve ADMIN_USER --static admin
resolve ADMIN_PASSWORD --gen 'rand_alnum 32'
secret_literal_args
kubectl create secret generic monitoring-grafana-admin --namespace monitoring \
  "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml > "$PLAIN"

secret_source monitoring monitoring-healthchecks
resolve PING_KEY --prompt "healthchecks.io ping key (from your account's project settings)"
secret_literal_args
{
  echo "---"
  kubectl create secret generic monitoring-healthchecks --namespace monitoring \
    "${SECRET_LITERAL_ARGS[@]}" --dry-run=client -o yaml
} >> "$PLAIN"

secret_finish
