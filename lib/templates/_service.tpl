{{- define "lib.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "lib.fullname" . }}
  namespace: {{ include "lib.namespace" . }}
  labels:
    {{- include "lib.selectorLabels" . | nindent 4 }}
spec:
  selector:
    {{- include "lib.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ include "lib.servicePort" . }}
      targetPort: {{ .Values.app.port }}
{{- end -}}
