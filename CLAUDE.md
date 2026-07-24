# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GitOps Kubernetes homelab: **k3s + ArgoCD + Helm**. There is no application source
code — everything is infrastructure config (YAML manifests + local Helm charts).
Changes are deployed by committing/pushing to `github.com/glazrtom/homelab.git`; ArgoCD
watches `HEAD` and auto-syncs (`automated: {prune, selfHeal}`). There is no CI, no
Makefile/Taskfile, and no build step.

## How deployment works

- Each service is registered as an ArgoCD `Application` CR in `applications/*.yaml`.
  These are applied manually (`kubectl apply -f applications/<svc>.yaml`) — there is no
  root app-of-apps that syncs the `applications/` directory itself.
- Each `Application` points at a per-service directory (`plex/`, `pihole/`, etc.) that
  is a self-contained local Helm chart (`Chart.yaml`, `values.yaml`, `templates/`).
- `media/` is different: `media/application/Application.yaml` is an **ApplicationSet**
  with a list generator that instantiates the same `media/` chart multiple times
  (prowlarr, shared PVCs, main) each with a different per-instance values file.

## Global values (shared config)

`global/values.yaml` holds cluster-wide values consumed by charts:
`global.user` (uid/gid 1002), `global.timezone` (Europe/Prague), and the domain
suffixes `global.domain.internal.suffix: internal` and
`global.domain.public.suffix: glazrtom.fun`.

Charts that need these values layer them via the ArgoCD `helm.valueFiles` list, e.g.
`authentik.yaml` and the media ApplicationSet list `../global/values.yaml` first, then
`values.yaml`, then any per-instance file. When adding a chart that references
`.Values.global.*`, you must add `../global/values.yaml` to its Application's
`valueFiles` or the sync will fail to template.

## Networking: dual ingress + global auth

Two `ingress-nginx` controllers run with separate IngressClasses (`ingress/nginx-external.yaml`,
`ingress/nginx-internal.yaml`), deployed as k3s-native `HelmChart` CRs (not ArgoCD apps).
Services typically expose **two** Ingress objects (see `plex/templates/ingress.yaml` and
`ingress-external.yaml`):

- Internal: `ingressClassName: nginx-internal`, host `<prefix>.internal` (LAN only, no auth).
- External: `ingressClassName: nginx-external`, host `<prefix>.<global.domain.public.suffix>`.

Path from the internet: **Cloudflare Tunnel (`cloudflare/`) → nginx-external → service.**
The `nginx-external` controller enforces **Authentik forward-auth on every external host**
via `global-auth-*` snippets in `ingress/nginx-external.yaml` (auth URL points at the
Authentik embedded outpost; `auth.glazrtom.fun` is exempted). It also maps Cloudflare's
`CF-Visitor` header to a real scheme and rewrites `X-Forwarded-Proto/Host`. This is the
"global domain auth" that recent commits iterate on — edit it there. `nginx-internal`
has no auth.

Authentik (SSO/IdP) is deployed from `authentik_helm/` (official upstream chart, with
bundled postgres + redis). `authentik/` is the older custom chart being migrated away
from — prefer `authentik_helm/`.

## Secrets

**Bitnami Sealed Secrets** is the mechanism (controller in `kube-system`). Encrypted
secrets are committed to git (`*/templates/sealed-*.yaml`, `base/github-credentials-sealed.yaml`).
To (re)generate one, run the service's `generate-secret.sh` (in `authentik/`,
`authentik_helm/`, `base/`, `cloudflare/`): it writes a plaintext secret to a
git-ignored `secrets/` dir, then runs `kubeseal` to produce the committed sealed file.
Never commit plaintext from `secrets/`. Some bootstrap secrets (VPN, TLS, Tailscale,
Cloudflare token) are instead created imperatively — see `init.sh`.

`base/generate-secret.sh` annotates the GHCR pull secret for **reflector**
(emberstack), which mirrors it into other namespaces.

## Bootstrap

`init.sh` is a **template, not a runnable script** (it exits immediately). It documents
the ordered one-time cluster setup: k3s → ArgoCD → MetalLB → mkcert TLS → VPN secret →
Tailscale operator → Cloudflare tunnel → Sealed Secrets controller.

## Conventions when adding/editing services

- New service = new directory with a Helm chart + a new `applications/<svc>.yaml`
  Application CR (copy an existing one; keep `repoURL`/`targetRevision: HEAD`/automated sync).
- Reference domains through `global.domain.*`, not hardcoded hostnames.
- Provide both internal and external Ingress objects following the plex pattern if the
  service should be reachable from the internet (external = behind Authentik).
