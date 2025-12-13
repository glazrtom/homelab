#! /bin/bash

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <tunnel-name-or-id>"
  echo "Example: $0 my-tunnel"
  exit 1
fi

TUNNEL_TOKEN=$(cloudflared tunnel token "$1")

mkdir -p secrets
echo "token.yaml" > secrets/.gitignore

kubectl create secret generic cloudflared-token \
  --namespace cloudflared \
  --from-literal=token="$TUNNEL_TOKEN" \
  --dry-run=client -o yaml > secrets/token.yaml

kubeseal --controller-namespace kube-system \
  --format yaml < secrets/token.yaml > templates/sealed-token.yaml
