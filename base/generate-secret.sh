#! /bin/bash

read -r -p "Enter GitHub username: " TOKEN
read -r -s -p "Enter GitHub PAT: " USERNAME
echo
read -r -p "Enter GitHub email: " EMAIL

if [ -z "${USERNAME:-}" ] || [ -z "${TOKEN:-}" ] || [ -z "${EMAIL:-}" ]; then
  echo "Error: username, token and email must be provided"
  exit 1
fi

mkdir -p secrets
chmod go-rwx secrets
echo "secrets/" > .gitignore

kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username="$USERNAME" \
  --docker-password="$TOKEN" \
  --docker-email="$EMAIL" \
  --namespace default \
  --dry-run=client -o yaml \
| kubectl annotate --local -f - \
   reflector.v1.k8s.emberstack.com/reflection-allowed=true \
   --output yaml > secrets/github-credentials.yaml

chmod go-rwx secrets/github-credentials.yaml

kubeseal --controller-namespace kube-system \
  --format yaml < secrets/github-credentials.yaml > github-credentials-sealed.yaml

unset USERNAME TOKEN EMAIL
