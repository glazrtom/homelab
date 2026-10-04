{{/* lib.deployment's sidecarsTemplate takes a single template name, so init-perms (runs once, first) and the exporter sidecar are chained here. */}}
{{- define "transmission.sidecars" -}}
{{ include "transmission.initPerms" . }}
{{ include "transmission.exporterContainer" . }}
{{- end -}}

{{/* Sidecar: Prometheus exporter reading Transmission's RPC over localhost (RPC auth is off). */}}
{{- define "transmission.exporterContainer" -}}
- name: exporter
  image: "{{ .Values.exporter.image.repository }}:{{ .Values.exporter.image.tag }}"
  restartPolicy: Always
  env:
    - name: TRANSMISSION_ADDR
      value: "http://localhost:{{ .Values.app.port }}"
    - name: WEB_ADDR
      value: ":{{ .Values.exporter.port }}"
  ports:
    - name: metrics
      containerPort: {{ .Values.exporter.port }}
  resources:
    {{- toYaml .Values.exporter.resources | nindent 4 }}
{{- end -}}
