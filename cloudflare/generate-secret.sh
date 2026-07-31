#! /bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source ../scripts/seal.sh

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <tunnel-name-or-id>"
  echo "Example: $0 my-tunnel"
  exit 1
fi

PLAIN=secrets/token.yaml
SEALED=templates/sealed-token.yaml

TUNNEL_TOKEN=$(cloudflared tunnel token "$1")

mkdir -p secrets
chmod go-rwx secrets
echo "token.yaml" > secrets/.gitignore

kubectl create secret generic cloudflared-token \
  --namespace cloudflared \
  --from-literal=token="$TUNNEL_TOKEN" \
  --dry-run=client -o yaml > "$PLAIN"
chmod go-rwx "$PLAIN"

seal_if_needed "$PLAIN" "$SEALED"
