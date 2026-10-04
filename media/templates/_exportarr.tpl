{{/*
Sidecar: per-app Prometheus metrics (health issues, indexer failures for prowlarr; queue
size via ENABLE_ADDITIONAL_METRICS). Shared across prowlarr/radarr/sonarr - CONFIG points exportarr at the same
config.xml already mounted for the main container, so it reads the API key straight
out of it instead of needing a secret of its own.
*/}}
{{- define "media.exportarrContainer" -}}
- name: exportarr
  image: "{{ .Values.global.exportarr.image.repository }}:{{ .Values.global.exportarr.image.tag }}"
  restartPolicy: Always
  args: ["{{ .Values.app.name }}"]
  env:
    - name: PORT
      value: {{ .Values.global.exportarr.port | quote }}
    - name: URL
      value: "http://localhost:{{ .Values.app.port }}"
    - name: ENABLE_ADDITIONAL_METRICS
      value: "true"
    - name: CONFIG
      value: "{{ .Values.volumes.config.mountPath }}/config.xml"
  ports:
    - name: metrics
      containerPort: {{ .Values.global.exportarr.port }}
  volumeMounts:
    - name: config
      mountPath: {{ .Values.volumes.config.mountPath }}
      readOnly: true
  resources:
    {{- toYaml .Values.global.exportarr.resources | nindent 4 }}
{{- end -}}
