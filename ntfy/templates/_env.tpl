{{/*
NTFY_BASE_URL needs global.domain.public.suffix, which a plain values.yaml can't
template - see lib.deployment's extraEnvTemplate hook. NTFY_UPSTREAM_BASE_URL is the
iOS instant-push relay: a poll-request (message ID only, never content) goes to
ntfy.sh, which forwards to APNs - see docs.ntfy.sh/config.
*/}}
{{- define "ntfy.env" -}}
{{- include "lib.env" (dict
  "env" (dict
    "NTFY_BASE_URL" (printf "https://%s.%s" .Values.app.domainPrefix .Values.global.domain.public.suffix)
    "NTFY_BEHIND_PROXY" "true"
    "NTFY_CACHE_FILE" (printf "%s/cache.db" .Values.volumes.data.mountPath)
    "NTFY_AUTH_FILE" (printf "%s/auth.db" .Values.volumes.data.mountPath)
    "NTFY_AUTH_DEFAULT_ACCESS" "deny-all"
    "NTFY_AUTH_ACCESS" "alertmanager:alerts:wo,media:media:wo"
    "NTFY_UPSTREAM_BASE_URL" "https://ntfy.sh"
  )
  "secretEnv" (dict
    "NTFY_AUTH_USERS" (dict "name" "ntfy-auth" "key" "NTFY_AUTH_USERS")
    "NTFY_AUTH_TOKENS" (dict "name" "ntfy-auth" "key" "NTFY_AUTH_TOKENS")
  )
) -}}
{{- end -}}
