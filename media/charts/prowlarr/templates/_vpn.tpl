{{/* Both prowlarr sidecars in one list - lib.deployment's sidecarsTemplate takes a
single template name, so vpn + exportarr are chained here rather than each app
setting sidecarsTemplate directly. */}}
{{- define "prowlarr.sidecars" -}}
{{ include "prowlarr.vpnContainer" . }}
{{ include "media.exportarrContainer" . }}
{{- end -}}

{{/* gluetun sidecar; prowlarr's traffic egresses through the VPN. */}}
{{- define "prowlarr.vpnContainer" -}}
- name: vpn
  image: {{ .Values.vpn.image }}
  imagePullPolicy: {{ .Values.global.imagePullPolicy }}
  restartPolicy: Always
  securityContext:
    capabilities:
      add:
        - NET_ADMIN
  env:
    {{- include "lib.env" (dict "env" .Values.vpn.env "secretEnv" .Values.vpn.secretEnv) | nindent 4 }}
  {{- with .Values.vpn.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  startupProbe:
    exec:
      command: ["/gluetun-entrypoint", "healthcheck"]
    periodSeconds: 5
    failureThreshold: 60
  readinessProbe:
    exec:
      command: ["/gluetun-entrypoint", "healthcheck"]
    periodSeconds: 30
{{- end -}}
