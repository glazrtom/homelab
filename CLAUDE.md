# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GitOps Kubernetes homelab: **k3s + ArgoCD + Helm**. There is no application source
code — everything is infrastructure config (YAML manifests + local Helm charts).
Changes are deployed by committing/pushing to `github.com/glazrtom/homelab.git`; ArgoCD
watches `HEAD` and auto-syncs (`automated: {prune, selfHeal}`). There is no CI, no
Makefile/Taskfile, and no build step.

**Everything runs on Kubernetes — there is no Docker Compose anywhere in this repo**, and
new services must not introduce it. A workload is a local Helm chart plus an ArgoCD
`Application`; multi-container workloads are pods with sidecars (e.g. prowlarr's gluetun
VPN sidecar in `media/`), not compose services. The single k3s node is provisioned by
`ansible/` (see Provisioning below); everything above the node is ArgoCD's.

## Git workflow

**Interactive sessions: never create branches, commit, or push — and don't offer to.**
Make the edits, validate them (below), and leave everything in the working tree; the human
drives git here. This holds even when the working tree is dirty or sitting on `master`.

**Headless `@claude` GitHub Action runs** (`.github/workflows/claude.yml` — issues, issue
comments, PR review comments) are the exception, and there the rule is mandatory: **work on
a feature branch and open a PR into `master`. Never push to `master` directly.** This is not
stylistic: ArgoCD watches `HEAD` of `master` with `automated: {prune, selfHeal}`, so anything
landing on `master` is deployed to the live cluster within minutes. The PR is the only gate
between an edit and production.

- Branch off `master` (`git switch -c <topic>`), commit there, push the branch, open a PR.
- Let the PR merge into `master`; that merge is what triggers the deploy.
- Commit with plain `-m` flags (repeat `-m` for extra paragraphs). Never wrap the message
  in a heredoc or `$(...)` — command substitution disables prefix permission matching, so
  a `$(cat <<EOF …)` commit is denied in headless runs even though `Bash(git commit:*)` is
  allowed.
- Interactive-only permission rules (e.g. `git commit`/`git push` under `ask`) belong in
  the git-ignored `.claude/settings.local.json`, not the tracked `.claude/settings.json` —
  the `@claude` GitHub Action loads project settings too, and an `ask` rule there outranks
  the workflow's `--allowedTools` and hard-denies in headless runs.

## Validation (both modes)

Validate whatever you touched before handing work back (interactive) or opening the PR
(headless):

- Charts: `helm template <chart>/ -f global/values.yaml -f <chart>/values.yaml` — a chart
  that fails to template leaves the Application stuck `OutOfSync` in the cluster.
- Ansible: `cd ansible && ansible-playbook --syntax-check playbooks/<pb>.yml` — the
  `--syntax-check` flag must come **immediately** after `ansible-playbook`, since that exact
  prefix is what the `@claude` Action allowlists (a full play run is deliberately not
  permitted).
- Plain YAML: `yamllint <file>` (chart templates are Go templates and are excluded via
  `.yamllint.yml`).

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
`global.domain.public.suffix: glazrtom.cz`, `global.sharedMedia` (name/size of the
shared Longhorn media volume — see Storage below), `global.ingress.{internal,external}.{className,loadBalancerIP}`
(the two IngressClass names and their MetalLB LB IPs — see Networking below), and
`global.authentik.{namespace,outpost.{service,port}}` (the one embedded outpost's
address, consumed by both the ingress chart's global auth and `lib.authOutpost*`).

Charts that need these values layer them via the ArgoCD `helm.valueFiles` list, e.g.
`authentik.yaml` and the media ApplicationSet list `../global/values.yaml` first, then
`values.yaml`, then any per-instance file. When adding a chart that references
`.Values.global.*`, you must add `../global/values.yaml` to its Application's
`valueFiles` or the sync will fail to template.

## Networking: dual ingress + global auth

Two `ingress-nginx` controllers run with separate IngressClasses, one per key under
`global.ingress` (`internal`/`external`). The `ingress/` chart renders one k3s-native
`helm.cattle.io/v1` `HelmChart` CR per controller (`ingress/templates/helmchart.yaml`);
controller-level config (forwarded headers, real-IP recovery, the Cloudflare scheme map,
global auth) lives in `ingress/templates/_config.tpl`. `lib.ingress` renders **two**
Ingress objects for any chart that uses it (see `lib/templates/_ingress.tpl`; plex and
calibre are hand-written exceptions):

- Internal: `ingressClassName: nginx-internal`, host `<prefix>.internal`.
- External: `ingressClassName: nginx-external`, host `<prefix>.<global.domain.public.suffix>`.

Path from the internet: **Cloudflare Tunnel (`cloudflare/`) → nginx-external → service.**
**Both classes are deny-by-default.** `authentik/values.yaml` `gatedApps` is the single
registry of gated hosts and the group allowed in; the blueprint
(`authentik/templates/blueprint-access.yaml`) generates **two** `forward_single` proxy
providers per entry — one for the public host, one for `<prefix>.internal` — so one
registry entry gates both classes at once. A host missing from `gatedApps` matches no
application, and the class's own `global-auth-url` (`ingress.internalConfig` /
`ingress.externalConfig` in `ingress/templates/_config.tpl`) turns that into a 403.

A chart sets exactly one of two states via `ingress.auth` — there is no third, implicit
one, and `lib.ingress` `fail`s the template if the key is missing:

| | `ingress.auth: true` | `ingress.auth: false` |
|---|---|---|
| both classes | gated via that class's own outpost | `enable-global-auth: "false"` |

`auth: true` also needs `lib.authOutpost` rendered in the chart (a
`service-authentik-outpost.yaml` template with `{{ include "lib.authOutpost" . }}`), which
creates the in-namespace `ExternalName` alias(es) and the `authentik-auth-headers`
ConfigMap the Ingress-level annotations reference; add a matching `gatedApps` entry too.
Hosts that must not be gated at all (plex, calibre, Authentik itself) set `auth: false`.

There are **two proxy outposts**, keyed the same way as `global.ingress`:
`global.authentik.outposts.{external,internal}`. The embedded (`external`) outpost's
`authentik_host` is hardcoded to the public host — for the embedded outpost,
`authentik_host_browser` has no effect, so browser redirects would leave the LAN if it
also served internal hosts. The `internal` outpost is a second, non-embedded, deployed
outpost (via the existing `sc-local` service connection) carrying only the `-internal`
providers, with `authentik_host` pointed at Authentik's in-cluster Service (`auth.internal`
resolves via Pi-hole, not cluster DNS) and `authentik_host_browser` at `auth.internal` — so
LAN logins never hairpin out through Cloudflare.

Native (non-browser) clients that can't follow an SSO redirect (Jellyfin's TV/mobile apps)
don't need an ungated host as an escape hatch: a `gatedApps` entry's `skipPathRegex`
excludes the client's own auth/API paths from the forward-auth check while the rest of the
host stays gated — see the `jellyfin` entry in `authentik/values.yaml`.

Forward-auth's headers (`X-authentik-*`) stop at nginx — Jellyfin itself never reads
them, so being forward-auth'd doesn't log a browser into Jellyfin. Browser SSO for
Jellyfin instead runs over two separate `authentik_providers_oauth2.oauth2provider`s
(`provider-jellyfin-oidc` / `provider-jellyfin-oidc-internal` in
`blueprint-access.yaml`), consumed by a community OIDC plugin installed by hand in the
Jellyfin UI (config lives in its PVC, like the LDAP plugin's). Because implicit-consent
is used, completing that OIDC round-trip is invisible when a browser already holds an
authentik session from forward-auth — so the two mechanisms compose into single
sign-on without either depending on the other. Split public/internal for the same
reason the proxy providers are: `auth.internal` and `auth.glazrtom.cz` don't share a
session cookie, and the plugin picks one fixed issuer host per provider config with no
per-request switching, so each host needs its own client and callback path to stay
invisible and to keep LAN logins off Cloudflare. This doesn't help native clients,
which still need the `skipPathRegex` carve-out above.

Routing ungated hosts *through* the outpost (a provider with `skip_path_regex: .*`) was
considered and rejected: nginx `auth_request` treats any non-2xx/401/403 as an error and
returns **500**, and the outpost is what evaluates the skip regex — so a `.*` host still
hard-depends on the Authentik pod. Every Authentik restart would take the *unauthenticated*
apps down, in exchange for no security gain.

`nginx-external` also maps Cloudflare's `CF-Visitor` header to a real scheme, rewrites
`X-Forwarded-Proto/Host`, and recovers the real client IP from `CF-Connecting-IP` (needed
for `ingress.rateLimit`, below, to key on the actual visitor rather than the shared
`cloudflared` pod IP). The manual Cloudflare-side layer — one rate-limiting rule, up to
five custom rules (geo/ASN/UA blocking), Bot Fight Mode — isn't expressible in
`cloudflare/templates/configMap.yaml`'s single `*.glazrtom.cz` catch-all and has to be set
in the Cloudflare dashboard directly.

`ingress.rateLimit` (external Ingress only — the LAN isn't this threat model) sets
`limit-rps`/`limit-connections`/`limit-burst-multiplier`. An ungated external host
(`auth: false`) gets a conservative default when `rateLimit` is left unset;
`rateLimit: false` disables it outright (needed for Authentik's own host, whose login flow
serves every gated app's assets and would break under a low cap); setting `rateLimit`
alongside `auth: true` is a template error — a gated host doesn't need the extra layer.

Authentik (SSO/IdP) is deployed from `authentik/` (official upstream chart, with a
bundled postgres, refactored onto the `lib/` templates like the other apps).

## Deploy verification (CI)

`.github/workflows/deploy.yml` runs on every push to `master`: it hard-refreshes the
`core`/`apps` app-of-apps Applications plus every child Application (via
`scripts/argocd-wait.sh`) so ArgoCD picks the commit up immediately instead of waiting out
its poll interval, then blocks until each is `Synced`/`Healthy` at that commit, failing the
job otherwise. This is the only automated signal that a push actually deployed cleanly —
there is no other CI in this repo.

It talks to ArgoCD over a dedicated, ungated host, `argo-ci.glazrtom.cz`
(`argocd/templates/ingress-ci.yaml`, `argocd.ci` in `argocd/values.yaml`) —
`argo.glazrtom.cz`/`argo.internal` stay gated by Authentik as normal, and `argo-ci` is
deliberately **not** registered in `authentik/values.yaml` `gatedApps`. It is not open to
the internet: **Cloudflare Access** sits in front of the tunnel and 403s any request
missing a service-token header pair before it ever reaches nginx or the cluster.
Authentication into ArgoCD itself is a separate, read-only API token for the `github-actions`
account (`argocd/templates/cm.yaml` declares it `apiKey`-only — no UI session possible;
`argocd/templates/rbac-cm.yaml` grants it `get` on `applications` only, nothing else).

One-time setup outside this repo (redo after provisioning a fresh cluster — the ArgoCD
token lives in `argocd-secret`, not git, so it does not survive a rebuild, like the sealed
secrets):

1. Cloudflare Zero Trust → Access → Service Auth → create a service token; record the
   Client ID/Secret (shown once).
2. Access → Applications → Add → Self-hosted, domain `argo-ci.glazrtom.cz`; policy Action
   = Service Auth, Include = that token. No other policy on the app.
3. From the LAN, once the chart has synced: `argocd login argo.internal --grpc-web` then
   `argocd account generate-token --account github-actions`.
4. Set GitHub repo secrets `ARGOCD_AUTH_TOKEN`, `CF_ACCESS_CLIENT_ID`,
   `CF_ACCESS_CLIENT_SECRET`.

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
Plaintext lives in per-chart `secrets/` dirs, git-ignored via the root `.gitignore`'s
`/*/secrets/` (top-level charts only — a `secrets/` dir nested deeper is **not** covered,
so keep plaintext at `<chart>/secrets/`). Some bootstrap secrets (TLS, Tailscale) are
instead created imperatively — see `init.sh`.

### Never commit

- Anything out of a `secrets/` dir — the plaintext `Secret` manifests the generate scripts
  read and write. Only the `kubeseal` output (`sealed-*.yaml`, `*-sealed.yaml`) is
  committable.
- Kubeconfigs. `ansible/roles/kubeconfig` fetches the cluster kubeconfig to `~/.kube/config`
  on the control node; it carries admin client certs and belongs nowhere in this repo.
- The Cloudflare tunnel token/credentials JSON, the GHCR PAT, Windscribe credentials, and
  the Authentik keys (Postgres password, Django secret key, akadmin bootstrap
  password/token, LDAP bind key, OIDC client secrets) in any un-sealed form.
- `.env` files or literal values pasted inline into a chart's `values.yaml` — charts
  reference secrets by name (`windscribe-auth`, `authentik-secrets`, …); they never inline
  them.
- Longhorn/PVC data dumps or backups.

If plaintext does get committed, the value is burned: rotate it at the source, re-run that
app's `generate-*.sh`, and commit the new sealed file — rewriting history alone is not
enough.

`authentik/generate-secret.sh` owns a single `authentik-secrets` secret carrying every
key the chart needs (Postgres password, Django secret key, akadmin bootstrap
password/token/email, LDAP bind key, Jellyfin OIDC client id/secrets). Each key
backfills independently — existing values are read back out of the git-ignored
plaintext and only missing keys are freshly generated — so adding a new key later
never re-rolls an existing one. None of these are safe to regenerate on a running
install: Postgres password / Django secret key break authentik <-> postgres auth
immediately, and the rest are pinned into the LDAP outpost provider or Jellyfin's
PVC-stored plugin config.

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
  tunnel and its wildcard DNS route if missing, then runs `cloudflare/generate-secret.sh` —
  the same `scripts/seal.sh` hash-gated reseal used by the other secrets — and prompts
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
- A new chart rendering `lib.ingress` must set `ingress.auth` — `true` (gated; add a
  `gatedApps` entry in `authentik/values.yaml` and render `lib.authOutpost` in the chart)
  or `false` (deliberately open on both classes). There is no third option; the template
  enforces it.
- Keep comments to the minimum necessary — prefer self-explanatory names; comment only
  non-obvious intent.
