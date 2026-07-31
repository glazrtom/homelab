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
  (cluster infra: reflector, MetalLB, ingress, ArgoCD self-config, Cloudflare) or `applications/apps/`
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
`global.user` (uid/gid 1001), `global.timezone` (Europe/Prague), the domain
suffixes `global.domain.internal.suffix: internal` and
`global.domain.public.suffix: glazrtom.cz`, and `global.sharedMedia` (name/size of the
shared Longhorn media volume — see Storage below).

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
Authentik embedded outpost; `auth.glazrtom.cz` is exempted). It also maps Cloudflare's
`CF-Visitor` header to a real scheme and rewrites `X-Forwarded-Proto/Host`. This is the
"global domain auth" that recent commits iterate on — edit it there. `nginx-internal`
has no auth.

Authentik (SSO/IdP) is deployed from `authentik/` (official upstream chart, with a
bundled postgres, refactored onto the `lib/` templates like the other apps).

## Storage

Bulk media and per-app config both live on **Longhorn** (cluster-default StorageClass
`longhorn`, plus `longhorn-bulk` for statically-bound volumes — see `longhorn/`). The
media library is one Longhorn **RWX** volume (`longhorn/templates/volume-shared-media.yaml`,
sized via `global.sharedMedia`), genuinely shared across the `media`, `transmission` and
`plex` namespaces: each namespace has its own static `PersistentVolume` pointing at the
same `csi.volumeHandle`, bound to that namespace's own PVC via `claimRef`. Config volumes
are plain dynamically-provisioned `longhorn` PVCs, one per app, following the
`pihole/templates/pvc-config.yaml` pattern. Resizing the shared volume is a two-line change
in `global/values.yaml` (`size` and `sizeBytes`, kept in sync); resizing a config PVC is a
one-line change to that app's `volume.config.size`. There is no host-path storage left in
any chart.

## Secrets

**Bitnami Sealed Secrets** is the mechanism (controller in `kube-system`). Encrypted
secrets are committed to git (`*/templates/sealed-*.yaml`, `base/github-credentials-sealed.yaml`,
`base/windscribe-sealed.yaml`). Each service's `generate-*-secret.sh` (in `authentik/`,
`base/`, `cloudflare/`) is **idempotent**: it reuses the plaintext
already sitting in its git-ignored `secrets/` dir if present, only generating (random
values) or prompting (human-supplied values, e.g. the GHCR PAT or Windscribe creds) when
that plaintext is missing, then calls `scripts/seal.sh` (shared helper) to reseal via
`kubeseal`. Resealing is itself skipped unless the plaintext hash changed or the committed
sealed file no longer validates against the live controller — `kubeseal`'s output is
non-deterministic (fresh random session key/padding per run), so an unconditional reseal
would show as a git diff on every run even with nothing to change. Sealed secrets are
encrypted against one specific cluster's key, so re-run these after provisioning a new
cluster — `ansible/roles/secrets` does this automatically (see Provisioning below).
`**/secrets/` is git-ignored at the repo root; never commit plaintext from it. Some
bootstrap secrets (TLS, Tailscale) are instead created imperatively — see `init.sh`.

`base/generate-secret.sh` annotates the GHCR pull secret for **reflector**
(emberstack), which mirrors it into other namespaces. `base/generate-windscribe-secret.sh`
does the same for the `windscribe-auth` VPN credential (namespace `default`), mirroring it
into `media` (prowlarr's gluetun sidecar) and `transmission` — neither of those charts owns
the secret itself, they only reference `windscribe-auth` by name.

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
ansible-galaxy collection install -r requirements.yml --upgrade   # first time / fresh host
ansible-playbook playbooks/cluster.yml -K   # stage 1: host + k3s + cluster foundation
ansible-playbook playbooks/apps.yml -K      # stage 2: workload apps
```

- **`playbooks/cluster.yml`** (the "one command" for a fresh host) runs, in order:
  `server_base` (hostname + dedicated `server` user/group at uid/gid 1001, login user
  joins the group) → `k3s` (installs k3s only, `--disable traefik --disable servicelb`)
  → `kubeconfig` (fetches the cluster kubeconfig to the **control node**, `~/.kube/config`,
  rewriting the API server IP — every later role in this playbook talks to the cluster
  from here on) → `helm` (helm + helm-diff) → `argocd` (namespace + upstream
  `install.yaml`) → `sealed_secrets` (installs the Sealed Secrets controller via Helm
  into `kube-system`) → `cloudflare` (installs/logs in `cloudflared` if needed, creates the
  tunnel and its wildcard DNS route if missing, fetches the token, and reseals
  `cloudflare/templates/sealed-token.yaml` if the token or committed secret changed, prompting
  before commit/push; any declined or failed step just skips the rest of the role rather than
  failing the play) → `argocd_apps` (applies `applications/core.yaml`). From there ArgoCD deploys reflector,
  MetalLB, ingress, its own self-config, and Cloudflare (see sync-wave annotations in
  `applications/core/*.yaml`).
- **`playbooks/apps.yml`** (stage 2) runs `secrets` (always resealing — see below) →
  `argocd_apps` (applies `applications/apps.yaml`; ArgoCD then deploys every workload
  under `applications/apps/`).
- The `secrets` role always runs, looping over the generate scripts of every app in its
  `secrets_items` list (`authentik/`, `base/` — GHCR and Windscribe).
  It only prompts for a script's human-supplied values when that script has no local
  plaintext yet; if the plaintext is already there, it's assumed correct and just
  resealed as-is, no prompt (leave a prompt blank to skip that one and keep its
  committed sealed file instead). It then commits and pushes just the sealed files that
  changed. Run it standalone via `playbooks/secrets.yml`, which also runs `cloudflare`
  first, without redeploying anything.
- Because `helm`/`sealed_secrets`/`argocd`/`cloudflare`/`argocd_apps`/`secrets` run on
  the **control node** (not the server) against the fetched kubeconfig, that machine
  needs `kubectl`, `helm`, `kubeseal`, and `git` (with push access to this repo)
  available; `cloudflared` is optional — the `cloudflare` role installs it itself (via
  `brew`/`apt-get`) if missing and prompted for, and warns-and-skips (never fails the
  play) if it can't get a working, logged-in `cloudflared`.
- `playbooks/storage.yml` (mount a disk at `/mnt/storage`) is situational — run
  individually, on demand.
- Prompt-bearing roles/playbooks (`storage`, `secrets`, and the `cloudflare` role's
  install/login/commit/push prompts) no-op or fall back sensibly when left blank — see
  each role/playbook for specifics.
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
