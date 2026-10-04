{{- define "lib.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "lib.fullname" . }}
  namespace: {{ include "lib.namespace" . }}
  labels:
    {{- include "lib.selectorLabels" . | nindent 4 }}
spec:
  replicas: {{ if hasKey .Values "replicaCount" }}{{ .Values.replicaCount }}{{ else }}1{{ end }}
  revisionHistoryLimit: {{ .Values.global.revisionHistoryLimit }}
  strategy:
    {{- if .Values.strategy }}
    {{- toYaml .Values.strategy | nindent 4 }}
    {{- else }}
    # RollingUpdate deadlocks a single-replica Deployment that mounts an RWO PVC as
    # soon as the scheduler puts the new pod on a different node than the old one -
    # the new pod can't attach the volume until the old one releases it, but
    # RollingUpdate won't kill the old one until the new one is Ready. Recreate avoids
    # this at the cost of brief downtime per rollout; a chart can still opt back into
    # RollingUpdate (e.g. a stateless multi-replica workload) via .Values.strategy.
    type: Recreate
    rollingUpdate: null
    {{- end }}
  selector:
    matchLabels:
      {{- include "lib.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "lib.selectorLabels" . | nindent 8 }}
    spec:
      {{- with .Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.dnsPolicy }}
      dnsPolicy: {{ . }}
      {{- end }}
      {{- with .Values.dnsConfig }}
      dnsConfig:
        {{- toYaml . | nindent 8 }}
      {{- end }}
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
          {{- with .Values.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if or .Values.app.ports .Values.app.port }}
          ports:
            {{- if .Values.app.ports }}
            {{- toYaml .Values.app.ports | nindent 12 }}
            {{- else }}
            - containerPort: {{ .Values.app.port }}
            {{- end }}
          {{- end }}
          env:
            {{- include "lib.userEnv" . | nindent 12 }}
            {{- with .Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
            {{- with .Values.extraEnvTemplate }}
            {{- include . $ | nindent 12 }}
            {{- end }}
          volumeMounts:
            {{- include "lib.volumeMounts" . | trim | nindent 12 }}
          {{- with .Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
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
