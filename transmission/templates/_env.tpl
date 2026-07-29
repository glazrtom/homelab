{{/* env vars derived from global.sharedMedia plus the windscribe-auth secret. */}}
{{- define "transmission.env" -}}
{{- include "lib.env" (dict
  "env" (dict
    "TRANSMISSION_DOWNLOAD_DIR" (printf "%s/downloads/complete" .Values.global.sharedMedia.mountPath)
    "TRANSMISSION_INCOMPLETE_DIR" (printf "%s/downloads/incomplete" .Values.global.sharedMedia.mountPath)
  )
  "secretEnv" (dict
    "OPENVPN_USERNAME" (dict "name" .Values.secrets.name "key" .Values.secrets.usernameKey)
    "OPENVPN_PASSWORD" (dict "name" .Values.secrets.name "key" .Values.secrets.passwordKey)
  )
) -}}
{{- end -}}
