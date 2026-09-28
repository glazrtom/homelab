{{/*
Sidecar: per-app Prometheus metrics (health issues, queue size, indexer failures for
prowlarr). Shared across prowlarr/radarr/sonarr - CONFIG points exportarr at the same
config.xml already mounted for the main container, so it reads the API key straight
out of it instead of needing a secret of its own.
*/}}
{{- define "media.exportarrContainer" -}}
- name: exportarr
  image: "{{ .Values.exportarr.image.repository }}:{{ .Values.exportarr.image.tag }}"
  restartPolicy: Always
  args: ["{{ .Values.app.name }}"]
  env:
    - name: PORT
      value: {{ .Values.exportarr.port | quote }}
    - name: URL
      value: "http://localhost:{{ .Values.app.port }}"
    - name: CONFIG
      value: "{{ .Values.volumes.config.mountPath }}/config.xml"
  ports:
    - name: metrics
      containerPort: {{ .Values.exportarr.port }}
  volumeMounts:
    - name: config
      mountPath: {{ .Values.volumes.config.mountPath }}
      readOnly: true
  resources:
    {{- toYaml .Values.exportarr.resources | nindent 4 }}
{{- end -}}
