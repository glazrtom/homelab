{{/*
Disables each Servarr app's own login
*/}}
{{- define "media.authEnv" -}}
{{- $app := .Values.app.name | upper -}}
{{- include "lib.env" (dict "env" (dict
    (printf "%s__AUTH__METHOD" $app) "External"
    (printf "%s__AUTH__REQUIRED" $app) "Enabled"
  )) -}}
{{- end -}}
