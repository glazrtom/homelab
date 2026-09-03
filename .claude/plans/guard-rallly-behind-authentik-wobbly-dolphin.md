# Guard Rallly behind Authentik — private routes only

## Context

`rallly.glazrtom.cz` is currently the only fully-open app on `nginx-external`: its Ingress
(rendered by the vendored OCI subchart) carries `enable-global-auth: "false"` and a single
`path: /`. Anyone on the internet can reach the dashboard, create polls, and register an
account with a magic-link email.

It can't simply be flipped to `ingress.auth: true` — Rallly's whole point is that people
who were *sent a poll link* vote without an account. Gating the host would break
`/invite/<id>`, and it can't be fixed with `skipPathRegex` either: the invite page is
driven by `/api/trpc/*`, so `/api` must stay open, which means an nginx-level gate can
never be the real access boundary.

So this does both halves:

1. **Authentik becomes the only way to get a Rallly session** — Rallly 4.12.3 supports a
   generic OIDC provider natively, so it gets a real OIDC client in the existing blueprint,
   and `EMAIL_LOGIN_ENABLED=false` turns off magic-link login (which also disables
   registration). Rallly's own session then guards pages *and* `/api/trpc`.
2. **Forward-auth covers the private page surface** — a second Ingress on the same host,
   gated by the external outpost, over the dashboard / settings / control-panel / poll
   creation paths. Defence in depth, and the only thing that stops an anonymous visitor
   creating polls at `/new` (Rallly has no setting for that).

Anonymous surface is unchanged: `/`, `/login`, `/forgot-password`, `/reset-password`,
`/invite/<id>`, `/e/<id>`, `/accept-invite/<id>`, `/api/*`, `/_next/*`, `/static/*`,
`manifest.json`.

Group allowed through both mechanisms: **`homelab-personal`**.

Route facts this rests on (Rallly v4.12.3, verified against the tag): `src/proxy.ts`
*rewrites* the locale in rather than redirecting, so public URLs carry no `/<locale>`
prefix; the dashboard lives at `(space)/(dashboard)` → `/`, `/polls`, `/events`,
`/calendar`; `(space)/settings`; `(optional-space)` → `/new`, `/poll/<id>`; and
`/invite/<id>`, `/e/<id>`, `/quick-create`, `/control-panel`, `/accept-invite/<id>` sit
directly under `[locale]`. `next.config.ts` redirects `/api/auth/callback/oidc` →
`/api/better-auth/oauth2/callback/oidc`, so the documented callback URL is the right one.

## Changes

### 1. Shared OIDC client secret — `base/`

Rallly's OIDC client is confidential, so the same secret has to reach both the `rallly`
namespace (as `OIDC_CLIENT_SECRET`) and Authentik (for the blueprint's `!Env`). Use the
reflector pattern already used for SMTP — one source of truth, no ordering problem
between the two `generate-*.sh` scripts.

- New `base/generate-rallly-oidc-secret.sh`, modelled directly on
  `base/generate-smtp-secret.sh`: `secret_source default rallly-oidc`,
  `resolve RALLLY_OIDC_CLIENT_SECRET --gen 'rand_alnum 64'`, `kubectl create secret
  generic rallly-oidc --namespace default`, piped through
  `kubectl annotate --local -f - $(reflector_annotations "rallly,authentik")`.
- Output sealed to `base/rallly-oidc-sealed.yaml` via `secret_finish` (never commit
  `base/secrets/`).
- The client **id** is not secret — it stays a plain value (`rallly`) in both values
  files, the way `argocdOidc.clientId` already does.

### 2. Authentik — OIDC client for Rallly

- `authentik/values.yaml`:
  - new `gatedApps` entry — `slug: rallly`, `name: Rallly`, `prefix: rallly`,
    `group: homelab-personal`. (The blueprint will also mint the `rallly-internal`
    forward-auth provider from this entry; there is no `rallly.internal` Ingress, so it is
    unused but harmless — the registry is deliberately one-entry-per-service.)
  - new `ralllyOidc` block mirroring `argocdOidc`: `enabled`, `clientId: rallly`,
    `slug: rallly-oidc`, `group: homelab-personal`.
  - add `- secretRef: {name: rallly-oidc}` to `authentik.global.envFrom` so the worker's
    hourly blueprint re-apply can resolve the `!Env`.
- `authentik/templates/blueprint-access.yaml` — copy the ArgoCD OIDC block
  (`provider-argocd-oidc`, lines ~325-361) with two differences: `client_type:
  confidential` with `client_secret: !Env RALLLY_OIDC_CLIENT_SECRET` (the `!Env` idiom is
  already used by the Jellyfin providers), and
  `redirect_uris: [{url: https://<rallly prefix>.{{ $public }}/api/auth/callback/oidc,
  matching_mode: strict}]`. Resolve the prefix from the `rallly` `gatedApps` entry with the
  same `$jellyfinApp`/`$argocdApp` lookup-and-`fail` guard, so the callback host can't
  drift from the gated host. Same scope mappings (openid/email/profile), same
  implicit-consent authorization flow, plus the `application` + `policybinding` to
  `group-homelab-personal`.
- `authentik/templates/job-blueprint-apply.yaml` — add the same
  `- secretRef: {name: rallly-oidc}` to the Job's `envFrom`, or the PostSync apply fails
  on the unresolvable `!Env`.

### 3. Rallly chart

- `applications/apps/rallly.yaml` — add the missing Helm block; nothing in the chart can
  reference `.Values.global.*` without it:
  ```yaml
      helm:
        valueFiles:
          - values.yaml
          - ../global/values.yaml
  ```
- `rallly/Chart.yaml` — add the `lib` dependency alongside the OCI one
  (`repository: file://../lib`, `version: 0.1.0`). `charts/*.tgz` and `Chart.lock` are
  git-ignored, so ArgoCD resolves both itself; run `helm dependency update rallly/`
  locally before templating.
- `rallly/values.yaml`:
  - top-level `namespace: rallly` (what `lib.namespace` reads).
  - a `privateIngress` block: `enabled`, and the gated path list
    `[/polls, /events, /calendar, /settings, /control-panel, /new, /quick-create, /poll]`,
    with a comment that these are Rallly route prefixes, not arbitrary strings.
  - leave `rallly.ingress` exactly as it is — it stays the ungated catch-all with its
    existing rate limits.
  - `rallly.extraEnv` gains: `OIDC_NAME: Authentik`,
    `OIDC_DISCOVERY_URL: https://auth.glazrtom.cz/application/o/rallly-oidc/.well-known/openid-configuration`
    (built from `global.domain.public.suffix`, not hardcoded), `OIDC_CLIENT_ID: rallly`,
    `OIDC_CLIENT_SECRET` via `secretKeyRef` on `rallly-oidc` /
    `RALLLY_OIDC_CLIENT_SECRET`, and `EMAIL_LOGIN_ENABLED: "false"`.
- New `rallly/templates/service-authentik-outpost.yaml` —
  `{{ include "lib.authOutpostObjects" (dict "root" . "external" true) }}` under
  `if .Values.privateIngress.enabled` (same shape as
  `media/templates/authentik-outpost.yaml`). It also emits the unused
  `authentik-outpost-internal` alias; that's the library's shape and not worth forking.
- New `rallly/templates/ingress-private.yaml` — hand-written, like
  `argocd/templates/ingress-ci.yaml`. Same host and class as the public one
  (`rallly.ingress.host`, `global.ingress.external.className`), no rate-limit annotations
  (a gated host doesn't get them — `lib.ingress` treats that combination as an error), and:
  - the four auth annotations, generated by reusing the library helpers rather than
    retyping them: `auth-url` from `lib.authOutpostFqdn` (class `external`) +
    `global.authentik.outposts.external.port`, `auth-signin`
    `https://<host>/outpost.goauthentik.io/start?rd=$escaped_request_uri`,
    `auth-response-headers` from `lib.authResponseHeaders`, `auth-proxy-set-headers`
    `<namespace>/authentik-auth-headers`.
  - paths: `/outpost.goauthentik.io` (Prefix) → `authentik-outpost-external:9000` for the
    sign-in round-trip, then one Prefix path per entry in `privateIngress.paths` → the
    subchart's `rallly` Service on port 80.

  nginx picks the longest matching prefix, so these win over the public Ingress's `/`
  while everything else keeps falling through to it ungated.

## Sequencing

1. Run `base/generate-rallly-oidc-secret.sh`, commit the sealed output **first** — the
   blueprint Job fails its PostSync hook if `rallly-oidc` isn't in the `authentik`
   namespace yet.
2. Then the Authentik + Rallly changes together.

`EMAIL_LOGIN_ENABLED=false` lands in the same change, as chosen. Two things to be aware of:

- Accounts are linked **by email**. The Authentik account used to sign in must carry the
  same email as the existing Rallly account, or the polls already in the database end up
  orphaned under a different user. Check the Authentik user's email before pushing.
- Rallly has had bugs linking OIDC identities to pre-existing accounts
  ([lukevella/rallly#2155](https://github.com/lukevella/rallly/issues/2155)). If the first
  OIDC login errors instead of landing on the dashboard, the rollback is one line:
  set `EMAIL_LOGIN_ENABLED: "true"` and re-sync to get magic-link login back.

## Verification

Before handing back:

- `helm dependency update rallly/` then
  `helm template rallly/ -f global/values.yaml -f rallly/values.yaml` — check the two
  Ingresses render on one host with the private paths carrying the auth quartet and the
  public `/` carrying `enable-global-auth: "false"`, and that the outpost ExternalName +
  `authentik-auth-headers` ConfigMap land in `namespace: rallly`.
- `helm template authentik/ -f global/values.yaml -f authentik/values.yaml` — the
  `provider-rallly-oidc` entry, its application/policybinding, and the `rallly` /
  `rallly-internal` forward-auth providers.
- `yamllint applications/apps/rallly.yaml base/rallly-oidc-sealed.yaml`.

After the human pushes and ArgoCD syncs:

- `mcp__kubernetes__resources_list` Ingresses in `rallly`; confirm the outpost
  ExternalName Service and ConfigMap exist there.
- `curl -sI https://rallly.glazrtom.cz/invite/anything` → 200/404 from Rallly, **not** a
  302 to `auth.glazrtom.cz`. Same for `/api/trpc/...` and a `/_next/...` asset.
- `curl -sI https://rallly.glazrtom.cz/polls` → 302 to
  `auth.glazrtom.cz/outpost.goauthentik.io/start?...`.
- In a browser: `/login` offers only "Authentik" (no email field), completing it lands on
  the dashboard as the existing user with their polls intact.
- Open a real poll invite link in a private window — voting works with no login.
