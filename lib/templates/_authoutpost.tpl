{{/*
Per-namespace plumbing for apps gated by their own Authentik provider
(ingress.authProvider). Both objects have to live in the app's namespace: an
Ingress backend must be a same-namespace Service, and ingress-nginx refuses a
cross-namespace auth-proxy-set-headers ConfigMap.
*/}}

{{- define "lib.authOutpostFqdn" -}}
{{- printf "%s.%s.svc.cluster.local" .Values.global.authentik.outpost.service .Values.global.authentik.namespace -}}
{{- end -}}

{{- define "lib.authResponseHeaders" -}}
Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-entitlements,X-authentik-email,X-authentik-name,X-authentik-uid
{{- end -}}

{{- define "lib.authOutpost" -}}
{{- $ing := .Values.ingress | default dict }}
{{- if and $ing.external $ing.authProvider }}
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost
  namespace: {{ include "lib.namespace" . }}
spec:
  type: ExternalName
  externalName: {{ include "lib.authOutpostFqdn" . }}
  ports:
    - port: {{ .Values.global.authentik.outpost.port }}
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
