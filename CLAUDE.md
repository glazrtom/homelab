# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GitOps Kubernetes homelab: **k3s + ArgoCD + Helm**. There is no application source
code — everything is infrastructure config (YAML manifests + local Helm charts).
Changes are deployed by committing/pushing to `github.com/glazrtom/homelab.git`; ArgoCD
watches `HEAD` and auto-syncs (`automated: {prune, selfHeal}`). There is no CI, no
Makefile/Taskfile, and no build step.

## How deployment works

- Each service is registered as an ArgoCD `Application` CR under `applications/core/`
  (cluster infra: MetalLB, ingress, ArgoCD self-config, Cloudflare) or `applications/apps/`
  (workloads: Plex, Pi-hole, media, Authentik, …). Two app-of-apps Applications —
  `applications/core.yaml` and `applications/apps.yaml` — point at those two directories
  and are applied by the Ansible playbooks (see Provisioning below); everything under
  them is then GitOps-synced automatically, no manual `kubectl apply` needed.
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

`init.sh` is a **template, not a runnable script** (it exits immediately). It predates
`ansible/` below and documents the original, fully manual one-time cluster setup order.
It's kept only as historical reference — use the Ansible playbooks for actually
provisioning a host now.

## Provisioning (Ansible)

`ansible/` provisions a host in two stages, each its own playbook, each component its
own role. `ansible.cfg` sets the inventory, so `-i` is never needed:

```
cd ~/projects/homelab/ansible
ansible-galaxy collection install -r requirements.yml   # first time / fresh host
ansible-playbook playbooks/cluster.yml -K   # stage 1: host + k3s + cluster foundation
ansible-playbook playbooks/apps.yml -K      # stage 2: workload apps
# or run both via: ansible-playbook playbooks/main.yml -K
```

- **`playbooks/cluster.yml`** (the "one command" for a fresh host) runs, in order:
  `server_base` (hostname + dedicated `server` user/group at uid/gid 1001, login user
  joins the group) → `k3s` (installs k3s only, `--disable traefik --disable servicelb`)
  → `kubeconfig` (fetches the cluster kubeconfig to the **control node**, `~/.kube/config`,
  rewriting the API server IP — every later role in this playbook talks to the cluster
  from here on) → `helm` (helm + helm-diff) → `sealed_secrets` (installs the Sealed
  Secrets controller via Helm into `kube-system`) → `argocd` (namespace + upstream
  `install.yaml`) → `cloudflare` (prompts for the tunnel token, reseals it against the
  live controller, and if it changed commits + pushes just `cloudflare/templates/sealed-token.yaml`;
  if left blank it falls back to the committed sealed secret, or fails if none exists yet)
  → `argocd_apps` (applies `applications/core.yaml`). From there ArgoCD deploys MetalLB,
  ingress, its own self-config, and Cloudflare (see sync-wave annotations in
  `applications/core/*.yaml`).
- **`playbooks/apps.yml`** (stage 2) applies `applications/apps.yaml`; ArgoCD then
  deploys every workload under `applications/apps/`.
- Because `helm`/`sealed_secrets`/`argocd`/`cloudflare`/`argocd_apps` run on the
  **control node** (not the server) against the fetched kubeconfig, that machine needs
  `kubectl`, `helm`, `kubeseal`, and `git` (with push access to this repo) available.
- `playbooks/storage.yml` (mount a disk at `/mnt/storage`) and `playbooks/vpn_secret.yml`
  (Windscribe VPN secret) are situational — run individually, on demand.
- Prompt-bearing roles/playbooks (`storage`, `vpn_secret`, and the `cloudflare` role's
  internal `pause` prompt) no-op or fall back sensibly when left blank — see each
  role/playbook for specifics.
- Tunables live in each role's `defaults/main.yml`. `kubeconfig_path` (the local,
  control-node kubeconfig used from `kubeconfig` onward) and `path_home` are shared via
  `group_vars/all.yml`.
- Provisions as the existing `glazrtom` user against the `[server]` host in `inventory.ini`
  — no separate bootstrap inventory.
- This tree was moved here from the `dotfiles` repo, which now only provisions desktop
  workstations.

## Conventions when adding/editing services

- New service = new directory with a Helm chart + a new `applications/apps/<svc>.yaml`
  Application CR (copy an existing one; keep `repoURL`/`targetRevision: HEAD`/automated
  sync). Cluster-infra components (not workloads) go in `applications/core/` instead.
- Reference domains through `global.domain.*`, not hardcoded hostnames.
- Provide both internal and external Ingress objects following the plex pattern if the
  service should be reachable from the internet (external = behind Authentik).
- Keep comments to the minimum necessary — prefer self-explanatory names; comment only
  non-obvious intent.
