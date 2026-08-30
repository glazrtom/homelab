{{/*
Resource base name. Suffixed with the ApplicationSet instance name when one is set,
so a chart can be deployed several times into the same namespace.
*/}}
{{- define "lib.fullname" -}}
{{- $inst := .Values.global.instanceName | default "" -}}
{{- if $inst -}}
{{- printf "%s-%s" .Values.app.name $inst -}}
{{- else -}}
{{- .Values.app.name -}}
{{- end -}}
{{- end -}}

{{/* Standalone charts set .Values.namespace, media instances set .Values.global.namespace. */}}
{{- define "lib.namespace" -}}
{{- .Values.namespace | default .Values.global.namespace -}}
{{- end -}}

{{- define "lib.selectorLabels" -}}
app: {{ include "lib.fullname" . }}
{{- end -}}

{{/* Service the ingresses point at: an upstream chart's service when overridden. */}}
{{- define "lib.serviceName" -}}
{{- (.Values.service | default dict).name | default (include "lib.fullname" .) -}}
{{- end -}}

{{- define "lib.servicePort" -}}
{{- (.Values.service | default dict).port | default .Values.app.port -}}
{{- end -}}

{{/* linuxserver images use PUID/PGID; plex wants PLEX_UID/PLEX_GID. */}}
{{- define "lib.userEnv" -}}
- name: {{ .Values.app.uidEnv | default "PUID" }}
  value: {{ .Values.global.user.uid | quote }}
- name: {{ .Values.app.gidEnv | default "PGID" }}
  value: {{ .Values.global.user.gid | quote }}
- name: TZ
  value: {{ .Values.global.timezone | quote }}
{{- end -}}

{{- define "lib.volumes" -}}
{{- range $name, $v := .Values.volumes }}
- name: {{ $name }}
  persistentVolumeClaim:
    claimName: {{ $v.claimName | default (printf "%s-%s-pvc" (include "lib.fullname" $) $name) }}
{{- end }}
{{- range $name, $d := .Values.devices }}
- name: {{ $name }}
  hostPath:
    path: {{ $d.path }}
    type: CharDevice
{{- end }}
{{- range $name, $c := .Values.configMapVolumes }}
- name: {{ $name }}
  configMap:
    name: {{ $c.name }}
{{- end }}
{{- end -}}

{{/* Env list from a plain map plus a map of secretKeyRef sources: {env: {...}, secretEnv: {NAME: {name, key}}}. */}}
{{- define "lib.env" -}}
{{- range $k, $v := .env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- range $k, $s := .secretEnv }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ $s.name }}
      key: {{ $s.key }}
{{- end }}
{{- end -}}

{{- define "lib.volumeMounts" -}}
{{- range $name, $v := .Values.volumes }}
- name: {{ $name }}
  mountPath: {{ $v.mountPath }}
  {{- with $v.subPath }}
  subPath: {{ . }}
  {{- end }}
{{- end }}
{{- range $name, $d := .Values.devices }}
- name: {{ $name }}
  mountPath: {{ $d.path }}
{{- end }}
{{- range $name, $c := .Values.configMapVolumes }}
- name: {{ $name }}
  mountPath: {{ $c.mountPath }}
  {{- with $c.subPath }}
  subPath: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}
