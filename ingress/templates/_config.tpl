{{/*
controller.config for the external ingress-nginx release: forwarded-header trust,
the Cloudflare CF-Visitor -> real-scheme map, and the deny-by-default global auth.
There is no catch-all Authentik provider, so this sends any host without its own
auth-url to an outpost that has no application for it; the outpost answers 400 and
nginx turns that into a 403. Gated hosts override this per Ingress via
ingress.authProvider (lib.ingress), and hosts that must not be gated opt out with
enable-global-auth: "false".
*/}}
{{- define "ingress.externalConfig" -}}
# Trust forwarded headers
use-forwarded-headers: "true"

# Map Cloudflare scheme to a real scheme
map-hash-bucket-size: "128"
http-snippet: |
  map $http_cf_visitor $real_scheme {
    default $scheme;
    ~*"https" https;
  }

# Override headers sent to backends
proxySetHeaders:
  X-Forwarded-Proto: "$real_scheme"

# X-Forwarded-Host is what the outpost matches a host on - nginx would otherwise
# send it the outpost's own service address. No global-auth-signin: every host
# reaching this path is a denial, not a login.
global-auth-snippet: |
  proxy_set_header X-Forwarded-Host $http_host;
enable-forwarded-headers: "true"
global-auth-url: "http://{{ .Values.global.authentik.outpost.service }}.{{ .Values.global.authentik.namespace }}.svc.cluster.local:{{ .Values.global.authentik.outpost.port }}/outpost.goauthentik.io/auth/nginx"
{{- end -}}
