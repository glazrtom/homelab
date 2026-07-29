{{/*
One PVC per .Values.volumes entry with create: true. storageClassName defaults to
longhorn — longhorn-bulk is reserved for the shared media volume, which is declared
statically and never rendered here.
*/}}
{{- define "lib.pvc" -}}
{{- range $name, $v := .Values.volumes }}
{{- if $v.create }}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ printf "%s-%s-pvc" (include "lib.fullname" $) $name }}
  namespace: {{ include "lib.namespace" $ }}
spec:
  storageClassName: {{ $v.storageClassName | default "longhorn" }}
  accessModes:
    - {{ $v.accessMode | default "ReadWriteOnce" }}
  resources:
    requests:
      storage: {{ $v.size }}
{{- end }}
{{- end }}
{{- end -}}
