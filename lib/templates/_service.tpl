{{- define "lib.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "lib.fullname" . }}
  namespace: {{ include "lib.namespace" . }}
spec:
  selector:
    {{- include "lib.selectorLabels" . | nindent 4 }}
  ports:
    - port: {{ include "lib.servicePort" . }}
      targetPort: {{ .Values.app.port }}
{{- end -}}
