{{/*
Sidecar: Pi-hole's own metrics (queries/s, % blocked, top clients). Talks to Pi-hole
over localhost since it's the same pod - no password needed, FTLCONF_webserver_api_password
is empty (see _env.tpl).
*/}}
{{- define "pihole.exporterContainer" -}}
- name: pihole-exporter
  image: "{{ .Values.piholeExporter.image.repository }}:{{ .Values.piholeExporter.image.tag }}"
  restartPolicy: Always
  env:
    - name: PIHOLE_HOSTNAME
      value: "localhost"
    - name: PIHOLE_PORT
      value: "80"
    - name: PORT
      value: {{ .Values.piholeExporter.port | quote }}
    - name: INTERVAL
      value: "60s"
  ports:
    - name: metrics
      containerPort: {{ .Values.piholeExporter.port }}
  resources:
    {{- toYaml .Values.piholeExporter.resources | nindent 4 }}
{{- end -}}
