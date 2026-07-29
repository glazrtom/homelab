{{- define "lib.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "lib.fullname" . }}
  namespace: {{ include "lib.namespace" . }}
  labels:
    {{- include "lib.selectorLabels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount | default 1 }}
  revisionHistoryLimit: {{ .Values.global.revisionHistoryLimit }}
  selector:
    matchLabels:
      {{- include "lib.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "lib.selectorLabels" . | nindent 8 }}
    spec:
      {{- if or .Values.sidecarsTemplate .Values.initContainers }}
      initContainers:
        {{- with .Values.sidecarsTemplate }}
        {{- include . $ | nindent 8 }}
        {{- end }}
        {{- with .Values.initContainers }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- end }}
      containers:
        - name: {{ .Values.app.name }}
          image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
          imagePullPolicy: {{ .Values.image.pullPolicy | default .Values.global.imagePullPolicy }}
          ports:
            - containerPort: {{ .Values.app.port }}
          env:
            {{- include "lib.userEnv" . | nindent 12 }}
            {{- with .Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
          volumeMounts:
            {{- include "lib.volumeMounts" . | trim | nindent 12 }}
          {{- with .Values.probes }}
          {{- toYaml . | nindent 10 }}
          {{- end }}
          {{- with .Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
      volumes:
        {{- include "lib.volumes" . | trim | nindent 8 }}
{{- end -}}
