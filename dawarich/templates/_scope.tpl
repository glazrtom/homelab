{{/*
lib.* reads only .Values, so a second/third/fourth component renders by handing it a
Values map made of that component's own block plus the shared keys it still needs.
Returns YAML; callers pipe it through fromYaml. Takes: root (the chart's .), component.
*/}}
{{- define "dawarich.scope" -}}
{{- $root := .root -}}
{{- $shared := dict
  "global" $root.Values.global
  "namespace" $root.Values.namespace
  "settings" $root.Values.settings
  "oidc" $root.Values.oidc
  "smtp" $root.Values.smtp
  "secretName" $root.Values.secretName
  "app" (dict "domainPrefix" $root.Values.app.domainPrefix) -}}
{{- toYaml (mergeOverwrite (deepCopy (index $root.Values .component)) $shared) -}}
{{- end -}}
