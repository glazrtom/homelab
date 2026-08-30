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
`ansible/` — see the `ansible-provisioning` skill for the full playbook order;
everything above the node is ArgoCD's.

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

## Validation — mandatory before handing work back

Validate whatever you touched before handing work back (interactive) or opening the PR
(headless). These are the commands; don't skip them because a task looks trivial — a
chart that fails to template leaves the Application stuck `OutOfSync` in the cluster, and
in a headless run nobody templates it before it merges:

- Charts: `helm template <chart>/ -f global/values.yaml -f <chart>/values.yaml`.
- Ansible: `cd ansible && ansible-playbook --syntax-check playbooks/<pb>.yml` (see the
  `ansible-provisioning` skill for why `--syntax-check` must come immediately after
  `ansible-playbook`).
- Plain YAML: `yamllint <file>` (chart templates are Go templates and are excluded via
  `.yamllint.yml`).

Cluster reads should go through the `mcp__kubernetes__*` MCP tools first, falling back to
sandboxed `kubectl --context homelab` for verbs the MCP doesn't cover (e.g. `rollout status`,
`wait`, `port-forward`, `kubeseal`, `helm status`/`list`, or `curl` to a LAN host). Prefix
that fallback with `NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 ` — the API
server is `https://10.0.0.1:6443`, and Claude Code's sandbox appends `10.0.0.0/8` (and the
other RFC1918 ranges) to `NO_PROXY`, so an unprefixed `kubectl` bypasses the sandbox's
filtering proxy and connects direct, which the sandbox denies at `connect()`. With the
prefix the request goes through the proxy, where `sandbox.network.allowedDomains`' `10.0.0.1`
entry admits it. A cluster command failing with `connect: operation not permitted` means
the prefix is missing, not a cue to reach for `dangerouslyDisableSandbox`; `*.internal`
hosts need no prefix (hostnames aren't matched by the CIDR entries).

Keep exploration commands inside the sandbox's built-in read-only set: use the
scratchpad's literal path rather than `$TMPDIR`, avoid `for … do … done` loops and
`$(...)` command substitution (which also disables prefix permission matching — relevant
for the `gh *` family, always unsandboxed per `excludedCommands`), and prefer parallel
`Read`/`Grep`/`Glob` calls over a `cd … ; cat a; cat b` chain.

## How deployment works

- Each service is registered as an ArgoCD `Application` CR under `applications/core/`
  (cluster infra: reflector, MetalLB, ingress, ArgoCD self-config, Cloudflare) or `applications/apps/`
  (workloads: Plex, Pi-hole, media, Authentik, …). Two app-of-apps Applications —
  `applications/core.yaml` and `applications/apps.yaml` — point at those two directories
  and are applied by the Ansible playbooks (see the `ansible-provisioning` skill);
  everything under them is then GitOps-synced automatically, no manual `kubectl apply`
  needed.
- Each `Application` points at a per-service directory (`plex/`, `pihole/`, etc.) that
  is a self-contained local Helm chart (`Chart.yaml`, `values.yaml`, `templates/`).
- `media/` is different: `media/application/Application.yaml` is an **ApplicationSet**
  with a list generator that instantiates the same `media/` chart multiple times
  (`media-global`: prowlarr + the shared PVC + the shared Authentik outpost objects;
  `media-personal`: radarr + sonarr) each with a different per-instance values file.

## Global values (shared config)

`global/values.yaml` holds cluster-wide values consumed by charts:
`global.user` (uid/gid 1001), `global.timezone` (Europe/Prague), the domain
suffixes `global.domain.internal.suffix: internal` and
`global.domain.public.suffix: glazrtom.cz`, `global.sharedMedia` (name/size of the
shared Longhorn media volume — see the `longhorn-config` skill), `global.ingress.{internal,external}.{className,loadBalancerIP}`
(the two IngressClass names and their MetalLB LB IPs — see the `authentik-ingress` skill),
and `global.authentik.{namespace,outposts.{external,internal}.{service,port}}` (the two
proxy outposts' addresses — see the `authentik-ingress` skill — consumed by both the
ingress chart's global auth and `lib.authOutpost*`).

Charts that need these values layer them via the ArgoCD `helm.valueFiles` list, e.g.
`authentik.yaml` and the media ApplicationSet list `../global/values.yaml` first, then
`values.yaml`, then any per-instance file. **When adding a chart that references
`.Values.global.*`, you must add `../global/values.yaml` to its Application's
`valueFiles` or the sync will fail to template.**

## Hard invariants

These are destructive or wrong-by-default if missed, so they stay here rather than in a
skill that might not fire:

- Both ingress classes are deny-by-default. A chart rendering `lib.ingress` **must** set
  `ingress.auth` (`true` or `false` — there is no third option, the template `fail`s
  without it), and `auth: true` additionally requires a `gatedApps` entry in
  `authentik/values.yaml` **and** `lib.authOutpost` rendered in the chart. Full detail,
  including the outpost architecture and OIDC clients: **`authentik-ingress` skill**.
- Every PV/PVC carries `argocd.argoproj.io/sync-options: Delete=false,Prune=false`, so
  neither a prune nor deleting the owning Application removes data — but a deleted-and-
  recreated config PVC comes back **empty**, since Longhorn keys the volume off the PVC's
  UID. Full detail, including recovery and backup constraints: **`longhorn-config`
  skill**.
- **Never rename a `media/application/Application.yaml` (or any ApplicationSet) generator
  element in place.** ArgoCD deletes the Application for the old name and creates a new
  one for the new name; the delete cascades into every resource that Application owned.
  This has happened once already and deleted prowlarr's config PVC. If a rename is
  genuinely needed, set `spec.syncPolicy.preserveResourcesOnDeletion: true` on the
  ApplicationSet first, push that, then rename.
- **Never commit:** anything out of a `secrets/` dir (only `kubeseal` output —
  `sealed-*.yaml`, `*-sealed.yaml` — is committable); kubeconfigs; the Cloudflare tunnel
  token/credentials, GHCR PAT, Windscribe credentials, or Authentik keys in any un-sealed
  form; `.env` files or literal values inlined into a chart's `values.yaml`; Longhorn/PVC
  data dumps or backups. If plaintext does get committed, the value is burned — rotate it
  at the source and reseal. Full detail on the sealing mechanism: **`secrets` skill**.

## Adding a new service (checklist)

The repo's most common non-trivial task, spanning several of the skills above:

1. New directory with a self-contained Helm chart (`Chart.yaml`, `values.yaml`,
   `templates/`) — copy an existing similar chart.
2. New `applications/apps/<svc>.yaml` Application CR (`applications/core/` instead for
   cluster infra, not a workload) — copy an existing one; keep `repoURL`/
   `targetRevision: HEAD`/automated sync.
3. If the chart references `.Values.global.*`, add `../global/values.yaml` to that
   Application's `helm.valueFiles`.
4. Set `ingress.auth` on any `lib.ingress` usage. If `true`: add a `gatedApps` entry
   (`authentik/values.yaml`) and render `lib.authOutpost` in the chart — see
   `authentik-ingress`.
5. If the service needs credentials, add a `generate-*-secret.sh` following the existing
   pattern and seal via `scripts/seal.sh` — see `secrets`.
6. Reference domains through `global.domain.*`, never hardcoded hostnames.
7. `helm template <chart>/ -f global/values.yaml -f <chart>/values.yaml` before handing
   back (see Validation above).

Keep comments to the minimum necessary elsewhere in the repo too — prefer
self-explanatory names; comment only non-obvious intent.

## Skills for domain detail

- **`authentik-ingress`** — both ingress classes, `gatedApps`, outposts, OIDC clients
  (Jellyfin, ArgoCD), the LDAP bind account, the blueprint and its apply Job.
- **`longhorn-config`** — resizing, volume retirement/recovery, the B2 backup target and
  its constraints. For a live-state usage/backup-health *report* instead of a config
  change, use `disk-report`.
- **`secrets`** — Sealed Secrets mechanics, each `generate-*-secret.sh`, rotation.
- **`ansible-provisioning`** — the two-stage playbook order, roles, provisioning a fresh
  host.
- **`argocd-ops`** — deploy-workflow failures, `argo-ci` access setup, the
  `argocd-server` OIDC-restart caveat. Not for routine deploy-status checks.
