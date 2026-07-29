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
