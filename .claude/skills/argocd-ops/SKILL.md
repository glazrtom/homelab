---
name: argocd-ops
description: This skill should be used when the deploy workflow is failing (timing out, an app stuck mid-sync, CI 401ing), ArgoCD login/SSO is bouncing back to the login page, or rebuilding argo-ci access after a fresh cluster. Covers scripts/argocd-wait.sh, the argo-ci.glazrtom.cz Cloudflare Access setup, and the argocd-server OIDC-restart caveat. NOT for routine "did the deploy go green" checks — that's a plain workflow-run lookup, not this skill.
---

# ArgoCD CI verification and access

## How CI verifies a deploy

`.github/workflows/deploy.yml` runs on every push to `master`: it hard-refreshes the
`core`/`apps` app-of-apps Applications plus every child Application (via
`scripts/argocd-wait.sh`) so ArgoCD picks the commit up immediately instead of waiting out
its poll interval, then blocks until each is `Synced`/`Healthy` at that commit **and** its
sync operation has left `Running`/`Terminating` — `app_ok()` checks
`.status.operationState.phase` alongside sync/health, since ArgoCD marks an app
`Synced`/`Healthy` as soon as resources reconcile, before any `PostSync` hook (e.g.
authentik's blueprint-apply Job — see the `authentik-ingress` skill) has finished. Without
that check a push could go green minutes before a `gatedApps`/OIDC-provider edit actually
took effect. This is the only automated signal that a push actually deployed cleanly —
there is no other CI in this repo. `ARGOCD_WAIT_TIMEOUT` is raised to 900s (workflow
`timeout-minutes: 20`) to give the blueprint-apply Job room to run.

If the workflow is timing out or an app is stuck mid-sync, start with `app_ok()`'s three
conditions above — usually one of them (most often the `PostSync` hook) is what's still
pending.

## `argo-ci` access

It talks to ArgoCD over a dedicated, ungated host, `argo-ci.glazrtom.cz`
(`argocd/templates/ingress-ci.yaml`, `argocd.ci` in `argocd/values.yaml`) —
`argo.glazrtom.cz`/`argo.internal` stay gated by Authentik as normal, and `argo-ci` is
deliberately **not** registered in `authentik/values.yaml` `gatedApps`. It is not open to
the internet: **Cloudflare Access** sits in front of the tunnel and 403s any request
missing a service-token header pair before it ever reaches nginx or the cluster.
Authentication into ArgoCD itself is a separate, read-only API token for the `github-actions`
account (`argocd/templates/cm.yaml` declares it `apiKey`-only — no UI session possible;
`argocd/templates/rbac-cm.yaml` grants it `get` on `applications` only, nothing else).

## ArgoCD's own SSO

`argo.glazrtom.cz`/`argo.internal` are also gated by their own forward-auth (like any
other `gatedApps` entry), but ArgoCD's login page used to still show its own
username/password form on top of that. `argocd/values.yaml` `oidc` gives ArgoCD a real
Authentik OIDC client — see the `authentik-ingress` skill for the client itself
(`argocdOidc`, public/PKCE, public-host-only issuer, `homelab-admins` → `role:admin`).
This skill owns only the server-side consequence of that client existing:

`argocd-server` caches its OIDC TLS client config once, at `SessionManager`
construction — it does not pick up a change to `oidc.config` in a running process. A
server that booted before `oidc.config` first existed (or before it changes ever again)
keeps using the pre-OIDC fallback, a certificate pool containing only ArgoCD's own
self-signed cert, so it rejects Authentik's real (Cloudflare-issued) certificate on
every session-token verification: login succeeds but every following API call 401s and
you're bounced straight back to the login page. **A `kubectl -n argocd rollout restart
deploy/argocd-server` is required any time `oidc.config` is added or changed** — this
is a live-cluster action, not something the chart can trigger, since Ansible's `argocd`
role owns that Deployment, not this chart.

The local `admin` account is kept enabled as break-glass: on the LAN it's reachable via
`argo.internal`'s login form as long as Authentik is up (SSO from there would redirect
out to the public host and fail), and via
`kubectl port-forward -n argocd svc/argocd-server 8080:80` if Authentik itself is down,
since that path depends on nothing but the cluster.

## One-time setup (redo after provisioning a fresh cluster)

The ArgoCD token lives in `argocd-secret`, not git, so it does not survive a rebuild,
like the sealed secrets:

1. Cloudflare Zero Trust → Access → Service Auth → create a service token; record the
   Client ID/Secret (shown once).
2. Access → Applications → Add → Self-hosted, domain `argo-ci.glazrtom.cz`; policy Action
   = Service Auth, Include = that token. No other policy on the app.
3. From the LAN, once the chart has synced: `argocd login argo.internal --grpc-web` then
   `argocd account generate-token --account github-actions`.
4. `kubectl -n argocd rollout restart deploy/argocd-server` — a fresh provision applies
   upstream `install.yaml` before ArgoCD ever syncs `argocd/` and adds `oidc.config`, so
   the server always boots pre-OIDC on a new cluster; without this restart, SSO 401s in
   a loop per above.
5. Set GitHub repo secrets `ARGOCD_AUTH_TOKEN`, `CF_ACCESS_CLIENT_ID`,
   `CF_ACCESS_CLIENT_SECRET`.
