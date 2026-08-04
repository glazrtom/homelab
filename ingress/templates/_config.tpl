{{/*
controller.config for the external ingress-nginx release: forwarded-header trust, real
client IP recovery, the Cloudflare CF-Visitor -> real-scheme map, and the
deny-by-default global auth. There is no catch-all Authentik provider, so this sends
any host without its own auth-url to the external outpost, which has no application
for a host outside gatedApps; the outpost answers 400 and nginx turns that into a 403.
Gated hosts override this per Ingress via ingress.auth: true (lib.ingress), and hosts
that must not be gated opt out with ingress.auth: false.
*/}}
{{- define "ingress.externalConfig" -}}
# Trust forwarded headers
use-forwarded-headers: "true"

# Recover the real client IP from Cloudflare's header rather than trusting whatever
# X-Forwarded-For the request already carries - required for limit-rps/limit-connections
# (lib.ingress rateLimit) to key on the actual visitor instead of one shared tunnel IP.
enable-real-ip: "true"
real-ip-header: "CF-Connecting-IP"
proxy-real-ip-cidr: {{ .Values.global.ingress.external.trustedProxyCidr | quote }}

proxy-body-size: "32m"

# Map Cloudflare scheme to a real scheme
map-hash-bucket-size: "128"
http-snippet: |
  map $http_cf_visitor $real_scheme {
    default $scheme;
    ~*"https" https;
  }

# X-Forwarded-Host is what the outpost matches a host on - nginx would otherwise
# send it the outpost's own service address. No global-auth-signin: every host
# reaching this path is a denial, not a login.
global-auth-snippet: |
  proxy_set_header X-Forwarded-Host $http_host;
global-auth-url: "http://{{ .Values.global.authentik.outposts.external.service }}.{{ .Values.global.authentik.namespace }}.svc.cluster.local:{{ .Values.global.authentik.outposts.external.port }}/outpost.goauthentik.io/auth/nginx"
{{- end -}}

{{/*
controller.config for the internal ingress-nginx release: the LAN gets no forwarded-
header trust (there's no reverse proxy in front of it) and no rate limiting (not the
threat model), just the deny-by-default global auth against the internal outpost.
*/}}
{{- define "ingress.internalConfig" -}}
global-auth-snippet: |
  proxy_set_header X-Forwarded-Host $http_host;
global-auth-url: "http://{{ .Values.global.authentik.outposts.internal.service }}.{{ .Values.global.authentik.namespace }}.svc.cluster.local:{{ .Values.global.authentik.outposts.internal.port }}/outpost.goauthentik.io/auth/nginx"
{{- end -}}
