{{/*
Internal ingress always; the nginx-external one only when ingress.external is set.
External hosts are behind Authentik forward-auth enforced by the nginx-external
controller itself (ingress/nginx-external.yaml), so nothing is added here.
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
  ingressClassName: nginx-internal
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
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "lib.fullname" . }}-ingress-external
  namespace: {{ include "lib.namespace" . }}
  {{- with $ing.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  ingressClassName: nginx-external
  rules:
    - host: {{ .Values.app.domainPrefix }}.{{ .Values.global.domain.public.suffix }}
      http:
        paths:
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
