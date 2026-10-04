{{/* Sidecar: Prometheus exporter that reads Jellyfin's API over localhost with an API key. */}}
{{- define "jellyfin.exporterContainer" -}}
- name: exporter
  image: "{{ .Values.exporter.image.repository }}:{{ .Values.exporter.image.tag }}"
  restartPolicy: Always
  args:
    - --jellyfin.address=http://localhost:{{ .Values.app.port }}
    - --web.listen-address=:{{ .Values.exporter.port }}
    - --collector.transcoding
    - --collector.tasks
    - --collector.activity
  env:
    - name: JELLYFIN_TOKEN
      valueFrom:
        secretKeyRef:
          name: {{ .Values.exporter.secret.name }}
          key: {{ .Values.exporter.secret.key }}
  ports:
    - name: metrics-exp
      containerPort: {{ .Values.exporter.port }}
  resources:
    {{- toYaml .Values.exporter.resources | nindent 4 }}
{{- end -}}
