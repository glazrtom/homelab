{{/*
Disables each Servarr app's own login: prowlarr/radarr/sonarr are already gated by
Authentik on both ingress classes, so the in-app Forms login is a redundant second
prompt. External beats/ignores config.xml and is never persisted back to it - unlike
a hand-edited config.xml (see Radarr#9353, where a duplicated AuthenticationMethod
entry got ignored), an env var is reapplied every start and can't drift.
AUTH__REQUIRED is pinned to Enabled rather than left to whatever's already in each
PVC's config.xml - the other option, DisabledForLocalAddresses, would drop the
X-Api-Key requirement for RFC1918 callers, and every caller here is one. The API key
schemes stay registered regardless of AUTH__METHOD, so Prowlarr's API-key sync to
Radarr/Sonarr is unaffected.
*/}}
{{- define "media.authEnv" -}}
{{- $app := .Values.app.name | upper -}}
{{- include "lib.env" (dict "env" (dict
    (printf "%s__AUTH__METHOD" $app) "External"
    (printf "%s__AUTH__REQUIRED" $app) "Enabled"
  )) -}}
{{- end -}}
