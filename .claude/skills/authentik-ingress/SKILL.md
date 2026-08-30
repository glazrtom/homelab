---
name: authentik-ingress
description: This skill should be used when working with Authentik (the SSO/IdP) or either ingress class in this homelab repo — adding or changing an Ingress, gating or ungating a host, editing authentik/values.yaml or blueprint-access.yaml, outposts, OIDC clients (Jellyfin, ArgoCD), the LDAP bind account, forward-auth/SSO/403/500 debugging, or a blueprint-apply Job that failed an ArgoCD sync. Triggers on "gate this host", "authentik", "outpost", "blueprint", "SSO", "forward-auth", "gatedApps", "ingress", "OIDC provider", "403"/"500 from nginx".
---

# Authentik + dual ingress

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

## The `ingress.auth` contract

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
These objects are namespace singletons keyed by fixed names — if several charts sharing
one namespace are split across multiple ArgoCD Applications (e.g. `media/`'s
per-instance Applications), only one of them may render `lib.authOutpost`/
`lib.authOutpostObjects`, or ArgoCD reports SharedResource/RepeatedResource warnings and
none of them reach `Synced`; see `media/templates/authentik-outpost.yaml` for the
pattern (the `media-global` instance owns them, gated by its own values flag).

## The two proxy outposts

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

## Rejected design: routing ungated hosts through the outpost

Routing ungated hosts *through* the outpost (a provider with `skip_path_regex: .*`) was
considered and rejected: nginx `auth_request` treats any non-2xx/401/403 as an error and
returns **500**, and the outpost is what evaluates the skip regex — so a `.*` host still
hard-depends on the Authentik pod. Every Authentik restart would take the *unauthenticated*
apps down, in exchange for no security gain. Don't re-propose this.

## OIDC beyond forward-auth: Jellyfin and ArgoCD

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

ArgoCD gets a real Authentik OIDC client too (`argocd/values.yaml` `oidc`, backed by
`authentik/values.yaml` `argocdOidc`, rendered in `blueprint-access.yaml`): public/PKCE,
so no client secret exists to seal. Because the authorization flow is
`default-provider-authorization-implicit-consent` and the browser already holds an
Authentik session from forward-auth, the round-trip is invisible — one click on "LOG IN
VIA AUTHENTIK" and you're in, already authorized via the `homelab-admins` →
`role:admin` mapping in `argocd-rbac-cm`. ArgoCD accepts only one `oidc.config` issuer,
so this points at the **public** host (`auth.glazrtom.cz`) only; there is no LAN-only
variant the way the proxy providers have one. For what happens on the `argocd-server`
side after this client is added or changed (a mandatory pod restart), see the
`argocd-ops` skill — that's a live-cluster consequence this skill doesn't own.

## `ingress.rateLimit`

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

## The blueprint and how it's applied

Authentik (SSO/IdP) is deployed from `authentik/` (official upstream chart, with a
bundled postgres, refactored onto the `lib/` templates like the other apps). Its
declarative config (`gatedApps`, providers, outposts, the LDAP bind account, Jellyfin's
and ArgoCD's OIDC clients) lives in one blueprint, rendered into the `authentik-blueprints`
ConfigMap by `authentik/templates/blueprint-access.yaml` and applied by
`authentik/templates/job-blueprint-apply.yaml`, an ArgoCD `PostSync` hook Job that runs
`Importer.apply()` (via `ak shell -c`, not the `ak apply_blueprint` management command —
that command also runs a full `Importer.validate()` dry-run first, roughly doubling
runtime for no benefit here) against the just-synced ConfigMap. This makes a `gatedApps`
edit live as soon as the sync's hooks finish, instead of waiting on the worker's own
hourly blueprint discovery; it also means a blueprint that fails to apply (bad model,
unresolvable `!Find`, wrong `!KeyOf` order) fails the Job — and, because the Job's exit
code is checked, the sync operation itself — rather than silently no-opping inside the
worker. The Job's image tag tracks the `authentik` subchart pin in `authentik/Chart.yaml`,
so bumping that dependency carries the Job along with it.

If a sync fails with this Job's name, the fix is almost always a bad blueprint edit —
re-read the diff to `blueprint-access.yaml` for the mistakes listed above before assuming
an infra problem.
