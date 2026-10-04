{{/*
Env for web and sidekiq. Secret-backed variables are emitted before the plain ones
because REDIS_URL interpolates $(REDIS_PASSWORD), and Kubernetes only expands variables
defined earlier in the list. Hosts and OIDC URLs need global.domain.*, which a plain
values.yaml can't template.
*/}}
{{- define "dawarich.env" -}}
{{- $v := .Values -}}
{{- $prefix := $v.app.domainPrefix -}}
{{- $public := printf "%s.%s" $prefix $v.global.domain.public.suffix -}}
{{- $internal := printf "%s.%s" $prefix $v.global.domain.internal.suffix -}}
{{- $secretEnv := dict -}}
{{- range $key := list "SECRET_KEY_BASE" "DATABASE_USERNAME" "DATABASE_PASSWORD" "REDIS_PASSWORD" -}}
{{- $_ := set $secretEnv $key (dict "name" $v.secretName "key" $key) -}}
{{- end -}}
{{/* Owned by authentik/generate-secret.sh and reflected into this namespace. */}}
{{- $_ := set $secretEnv "OIDC_CLIENT_SECRET" (dict "name" $v.oidc.secretName "key" "OIDC_CLIENT_SECRET") -}}
{{- $env := mergeOverwrite (deepCopy $v.settings) (dict
  "APPLICATION_HOSTS" (printf "%s,%s,localhost" $public $internal)
  "TIME_ZONE" $v.global.timezone
  "REDIS_URL" "redis://:$(REDIS_PASSWORD)@dawarich-redis:6379"
  "OIDC_ISSUER" (printf "https://auth.%s/application/o/%s/" $v.global.domain.public.suffix $v.oidc.slug)
  "OIDC_REDIRECT_URI" (printf "https://%s/users/auth/openid_connect/callback" $public)
  "OIDC_CLIENT_ID" $v.oidc.clientId
  "OIDC_PROVIDER_NAME" $v.oidc.providerName
  "OIDC_AUTO_REGISTER" "true"
  "ALLOW_EMAIL_PASSWORD_REGISTRATION" "false"
  "ALLOW_EMAIL_PASSWORD_LOGIN" "false"
) -}}
{{- include "lib.env" (dict "secretEnv" $secretEnv) -}}
{{- include "lib.env" (dict "env" $env) -}}
{{- end -}}

{{/* The postgis image's own variables, fed from the same Secret the app reads. */}}
{{- define "dawarich.postgisEnv" -}}
{{- include "lib.env" (dict
  "env" (dict "POSTGRES_DB" .Values.settings.DATABASE_NAME "PGDATA" (printf "%s/pgdata" .Values.volumes.data.mountPath))
  "secretEnv" (dict
    "POSTGRES_USER" (dict "name" .Values.secretName "key" "DATABASE_USERNAME")
    "POSTGRES_PASSWORD" (dict "name" .Values.secretName "key" "DATABASE_PASSWORD")
  )
) -}}
{{- end -}}

{{- define "dawarich.redisEnv" -}}
{{- include "lib.env" (dict
  "secretEnv" (dict "REDIS_PASSWORD" (dict "name" .Values.secretName "key" "REDIS_PASSWORD"))
) -}}
{{- end -}}
