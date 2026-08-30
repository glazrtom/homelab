#! /bin/bash
# Cloudflare tunnel token. `cloudflared tunnel token` needs the tunnel name/ID as
# an argument (not a prompt-able secret), so it's wired up as this key's --gen
# rather than a --prompt: local plaintext or the live cluster value is reused
# first, and `cloudflared` is only invoked when neither is available.
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/secretlib.sh

secret_parse_args "$@"
if [ "${#SECRET_ARGS[@]}" -ne 1 ]; then
  echo "Usage: $0 [--force] <tunnel-name-or-id>"
  echo "Example: $0 my-tunnel"
  exit 1
fi
TUNNEL_ID="${SECRET_ARGS[0]}"

secret_init secrets/token.yaml templates/sealed-token.yaml
secret_source cloudflared cloudflared-token
echo "token.yaml" > secrets/.gitignore

resolve token --gen 'cloudflared tunnel token "$TUNNEL_ID"' --env TUNNEL_TOKEN

kubectl create secret generic cloudflared-token \
  --namespace cloudflared \
  --from-literal=token="$token" \
  --dry-run=client -o yaml > "$PLAIN"

secret_finish
