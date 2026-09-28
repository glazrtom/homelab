{{/*
Renders one Ingress per class: nginx-internal always, nginx-external when
ingress.external is set. Both classes deny by default - ingress.auth is mandatory and
picks one of two states:
  auth: true  - gated by Authentik forward-auth, via that class's own outpost (needs a
                matching gatedApps entry in authentik/values.yaml and lib.authOutpost
                rendered in this chart).
  auth: false - nginx.ingress.kubernetes.io/enable-global-auth: "false" on both
                Ingresses (a deliberately public/ungated host).
There is no third, implicit state - lib.ingress fails the template if auth is unset.
*/}}
{{- define "lib.ingress" -}}
{{- $ing := .Values.ingress | default dict }}
{{- if $ing.enabled | default true }}
{{- if not (hasKey $ing "auth") }}
{{- fail (printf "%s: set ingress.auth - true (gated; needs a gatedApps entry in authentik/values.yaml) or false (deliberately open). Both ingress classes deny by default." (include "lib.fullname" .)) }}
{{- end }}
{{- if and $ing.auth (hasKey $ing "rateLimit") }}
{{- fail (printf "%s: ingress.rateLimit only applies when ingress.auth is false - a gated host doesn't need the extra layer" (include "lib.fullname" .)) }}
{{- end }}
{{- $svc := include "lib.serviceName" . }}
{{- $port := include "lib.servicePort" . }}
{{- $extHost := $ing.externalHost | default (printf "%s.%s" .Values.app.domainPrefix .Values.global.domain.public.suffix) }}
{{- $intHost := printf "%s.%s" .Values.app.domainPrefix .Values.global.domain.internal.suffix }}
{{ include "lib.ingressDoc" (dict "root" . "class" "internal" "host" $intHost "scheme" "http" "className" .Values.global.ingress.internal.className "svc" $svc "port" $port "ing" $ing) }}
{{- if $ing.external }}
---
{{ include "lib.ingressDoc" (dict "root" . "class" "external" "host" $extHost "scheme" "https" "className" .Values.global.ingress.external.className "svc" $svc "port" $port "ing" $ing) }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "lib.ingressDoc" -}}
{{- $root := .root }}
{{- $class := .class }}
{{- $host := .host }}
{{- $scheme := .scheme }}
{{- $ing := .ing }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "lib.fullname" $root }}-ingress{{ if eq $class "external" }}-external{{ end }}
  namespace: {{ include "lib.namespace" $root }}
  annotations:
    {{- with $ing.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- include "lib.ingressAuthAnnotations" (dict "root" $root "class" $class "host" $host "scheme" $scheme "auth" $ing.auth) | nindent 4 }}
    {{- if eq $class "external" }}
    {{- $rl := include "lib.ingressRateLimitAnnotations" (dict "ing" $ing) }}
    {{- if $rl }}
    {{- $rl | nindent 4 }}
    {{- end }}
    {{- end }}
spec:
  ingressClassName: {{ .className }}
  rules:
    - host: {{ $host }}
      http:
        paths:
          {{- if $ing.auth }}
          # The sign-in round-trip lands here: the session cookie is per-provider, so
          # it has to be issued on this host rather than on Authentik's own host.
          - path: /outpost.goauthentik.io
            pathType: Prefix
            backend:
              service:
                name: authentik-outpost-{{ $class }}
                port:
                  number: {{ (index $root.Values.global.authentik.outposts $class).port }}
          {{- end }}
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .svc }}
                port:
                  number: {{ .port }}
{{- end -}}

{{/*
Either the auth quartet (pointed at this class's own outpost and host) or the explicit
opt-out annotation. Never empty, so the parent's "annotations:" key is always valid.
*/}}
{{- define "lib.ingressAuthAnnotations" -}}
{{- $root := .root -}}
{{- $class := .class -}}
{{- $host := .host -}}
{{- $scheme := .scheme -}}
{{- if .auth -}}
{{- $outpost := index $root.Values.global.authentik.outposts $class -}}
nginx.ingress.kubernetes.io/auth-url: http://{{ include "lib.authOutpostFqdn" (dict "root" $root "class" $class) }}:{{ $outpost.port }}/outpost.goauthentik.io/auth/nginx
nginx.ingress.kubernetes.io/auth-signin: {{ $scheme }}://{{ $host }}/outpost.goauthentik.io/start?rd=$escaped_request_uri
nginx.ingress.kubernetes.io/auth-response-headers: {{ include "lib.authResponseHeaders" $root }}
nginx.ingress.kubernetes.io/auth-proxy-set-headers: {{ include "lib.namespace" $root }}/authentik-auth-headers
{{- else -}}
nginx.ingress.kubernetes.io/enable-global-auth: "false"
{{- end }}
{{- end -}}

{{/*
Opt-in per-IP rate limiting, external Ingress only - the LAN is not this threat model.
Explicit ingress.rateLimit wins; unset + ingress.auth: false gets a conservative default
so an open public host is never limit-less; ingress.rateLimit: false disables it
outright (needed for hosts like Authentik's own, whose login flow serves every gated
app's assets and would break under a low cap).
*/}}
{{- define "lib.rateLimitDefault" -}}
rps: 20
connections: 20
burstMultiplier: 5
{{- end -}}

{{- define "lib.ingressRateLimitAnnotations" -}}
{{- $ing := .ing -}}
{{- $rl := dict -}}
{{- if hasKey $ing "rateLimit" -}}
{{- if $ing.rateLimit -}}
{{- $rl = $ing.rateLimit -}}
{{- end -}}
{{- else if not $ing.auth -}}
{{- $rl = include "lib.rateLimitDefault" . | fromYaml -}}
{{- end -}}
{{- $lines := list -}}
{{- if $rl.rps -}}{{- $lines = append $lines (printf "nginx.ingress.kubernetes.io/limit-rps: %s" ($rl.rps | quote)) -}}{{- end -}}
{{- if $rl.connections -}}{{- $lines = append $lines (printf "nginx.ingress.kubernetes.io/limit-connections: %s" ($rl.connections | quote)) -}}{{- end -}}
{{- if $rl.burstMultiplier -}}{{- $lines = append $lines (printf "nginx.ingress.kubernetes.io/limit-burst-multiplier: %s" ($rl.burstMultiplier | quote)) -}}{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
