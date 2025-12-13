#!/usr/bin/env bash

# K3s
curl -sfL https://get.k3s.io | sh -

# ArgoCD
sudo kubectl create namespace argocd
sudo kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

sudo kubectl apply -f argocd-ingress.yml
sudo kubectl apply -f argocd-disable-internal-tls.yml

# Nginx
#sudo kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.2/deploy/static/provider/cloud/deploy.yaml

# Metallb
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml

# Cert
mkcert -cert-file server.pem -key-file server-key.pem "*.server.local"
kubectl create secret tls homelab-tls \
  --namespace kube-system \
  --cert=homelab.pem \
  --key=homelab-key.pem

# VPN
kubectl create secret generic windscribe-auth \
  --namespace=media \
  --from-file=ovpn=Windscribe-Prague-Vltava.ovpn \
  --from-file=auth.txt=auth.txt \
  --from-literal=username="$(head -n 1 auth.txt)" \
  --from-literal=password="$(tail -n 1 auth.txt)"

# Tailscale
# https://tailscale.com/kb/1236/kubernetes-operator
helm upgrade \
  --install \
  tailscale-operator \
  tailscale/tailscale-operator \
  --namespace=tailscale \
  --create-namespace \
  --set-string oauth.clientId="" \
  --set-string oauth.clientSecret="" \
  --wait

## Inspired by https://github.com/mitchross/k3s-argocd-starter
# Cloudflare
#helm repo add cloudflare https://cloudflare.github.io/helm-charts
#helm repo update
TUNNEL_NAME=cloudflare-tunnel
DOMAIN=
cloudflared tunnel login
cloudflared tunnel create $TUNNEL_NAME
# cloudflared tunnel token --cred-file <tunnel-creds>.json $TUNNEL_NAME
cloudflared tunnel token $TUNNEL_NAME # gets encoded cloudflare token
# Create namespace for cloudflared
kubectl create namespace cloudflared
# Create Kubernetes secret
kubectl create secret generic cloudflare-token \
  --namespace=cloudflared \
  --from-literal=token=""

# Configure DNS
TUNNEL_ID=$(cloudflared tunnel list | grep $TUNNEL_NAME | awk '{print $1}')
cloudflared tunnel route dns $TUNNEL_ID "*.$DOMAIN"

# SealedSecrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm install sealed-secrets -n kube-system --set-string fullnameOverride=sealed-secrets-controller sealed-secrets/sealed-secrets
