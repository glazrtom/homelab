{{/*
Internal ingress always; the nginx-external one only when ingress.external is set.
External hosts are behind Authentik forward-auth enforced by the nginx-external
controller itself (ingress/templates/_config.tpl), so nothing is added here - unless
ingress.authProvider names a per-app provider, which overrides that global auth with
its own so the app can have its own allowlist. Such apps also need
lib.authOutpost rendered in their chart.
*/}}
{{- define "lib.ingress" -}}
{{- $ing := .Values.ingress | default dict }}
{{- if $ing.enabled | default true }}
{{- $svc := include "lib.serviceName" . }}
{{- $port := include "lib.servicePort" . }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "lib.fullname" . }}-ingress
  namespace: {{ include "lib.namespace" . }}
  {{- with $ing.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.global.ingress.internal.className }}
  rules:
    - host: {{ .Values.app.domainPrefix }}.{{ .Values.global.domain.internal.suffix }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $svc }}
                port:
                  number: {{ $port }}
{{- if $ing.external }}
{{- $extHost := $ing.externalHost | default (printf "%s.%s" .Values.app.domainPrefix .Values.global.domain.public.suffix) }}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "lib.fullname" . }}-ingress-external
  namespace: {{ include "lib.namespace" . }}
  {{- if or $ing.annotations $ing.authProvider }}
  annotations:
    {{- with $ing.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- if $ing.authProvider }}
    # An Ingress-level auth-url replaces the controller's global auth for this host,
    # so the gate becomes the {{ $ing.authProvider }} provider and its own bindings.
    nginx.ingress.kubernetes.io/auth-url: http://{{ include "lib.authOutpostFqdn" . }}:{{ .Values.global.authentik.outpost.port }}/outpost.goauthentik.io/auth/nginx
    nginx.ingress.kubernetes.io/auth-signin: https://{{ $extHost }}/outpost.goauthentik.io/start?rd=$escaped_request_uri
    nginx.ingress.kubernetes.io/auth-response-headers: {{ include "lib.authResponseHeaders" . }}
    nginx.ingress.kubernetes.io/auth-proxy-set-headers: {{ include "lib.namespace" . }}/authentik-auth-headers
    {{- end }}
  {{- end }}
spec:
  ingressClassName: {{ .Values.global.ingress.external.className }}
  rules:
    - host: {{ $extHost }}
      http:
        paths:
          {{- if $ing.authProvider }}
          # The sign-in round-trip lands here: the session cookie is per-provider, so
          # it has to be issued on this host rather than on the Authentik one.
          - path: /outpost.goauthentik.io
            pathType: Prefix
            backend:
              service:
                name: authentik-outpost
                port:
                  number: {{ .Values.global.authentik.outpost.port }}
          {{- end }}
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ $svc }}
                port:
                  number: {{ $port }}
{{- end }}
{{- end }}
{{- end -}}
