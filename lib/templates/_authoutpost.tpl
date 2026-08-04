{{/*
Per-namespace plumbing for apps gated by Authentik (ingress.auth: true). Both objects
have to live in the app's namespace: an Ingress backend must be a same-namespace
Service, and ingress-nginx refuses a cross-namespace auth-proxy-set-headers ConfigMap.
*/}}

{{- define "lib.authOutpostFqdn" -}}
{{- printf "%s.%s.svc.cluster.local" (index .root.Values.global.authentik.outposts .class).service .root.Values.global.authentik.namespace -}}
{{- end -}}

{{- define "lib.authResponseHeaders" -}}
Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-entitlements,X-authentik-email,X-authentik-name,X-authentik-uid
{{- end -}}

{{- define "lib.authOutpost" -}}
{{- $ing := .Values.ingress | default dict }}
{{- if $ing.auth }}
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost-internal
  namespace: {{ include "lib.namespace" . }}
spec:
  type: ExternalName
  externalName: {{ include "lib.authOutpostFqdn" (dict "root" . "class" "internal") }}
  ports:
    - port: {{ .Values.global.authentik.outposts.internal.port }}
{{- if $ing.external }}
---
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost-external
  namespace: {{ include "lib.namespace" . }}
spec:
  type: ExternalName
  externalName: {{ include "lib.authOutpostFqdn" (dict "root" . "class" "external") }}
  ports:
    - port: {{ .Values.global.authentik.outposts.external.port }}
{{- end }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-auth-headers
  namespace: {{ include "lib.namespace" . }}
data:
  # Authentik resolves which application gates a host from X-Forwarded-Host; the
  # auth subrequest would otherwise carry the outpost's own service address.
  X-Forwarded-Host: $http_host
{{- end }}
{{- end -}}
