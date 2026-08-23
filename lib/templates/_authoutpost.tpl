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

{{/*
The Service(s)/ConfigMap bodies alone, for a caller that renders them under its own
condition (e.g. a chart shared by several ArgoCD Applications in one namespace, where
only one of them may own these namespace-singleton objects - see media/templates). Takes
a dict: root (the chart's .), external (bool, whether to also render the external alias).
*/}}
{{- define "lib.authOutpostObjects" -}}
{{- $root := .root }}
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost-internal
  namespace: {{ include "lib.namespace" $root }}
spec:
  type: ExternalName
  externalName: {{ include "lib.authOutpostFqdn" (dict "root" $root "class" "internal") }}
  ports:
    - port: {{ $root.Values.global.authentik.outposts.internal.port }}
{{- if .external }}
---
apiVersion: v1
kind: Service
metadata:
  name: authentik-outpost-external
  namespace: {{ include "lib.namespace" $root }}
spec:
  type: ExternalName
  externalName: {{ include "lib.authOutpostFqdn" (dict "root" $root "class" "external") }}
  ports:
    - port: {{ $root.Values.global.authentik.outposts.external.port }}
{{- end }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-auth-headers
  namespace: {{ include "lib.namespace" $root }}
data:
  # Authentik resolves which application gates a host from X-Forwarded-Host; the
  # auth subrequest would otherwise carry the outpost's own service address.
  X-Forwarded-Host: $http_host
{{- end -}}

{{- define "lib.authOutpost" -}}
{{- $ing := .Values.ingress | default dict }}
{{- if $ing.auth }}
{{ include "lib.authOutpostObjects" (dict "root" . "external" $ing.external) }}
{{- end }}
{{- end -}}
