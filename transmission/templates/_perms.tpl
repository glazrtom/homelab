{{/* busybox initContainer that pre-creates and chowns the shared media dirs. */}}
{{- define "transmission.initPerms" -}}
- name: init-perms
  image: {{ .Values.initPerms.image.repository }}:{{ .Values.initPerms.image.tag }}
  command:
    - sh
    - -c
    - >-
      mkdir -p {{ range .Values.global.sharedMedia.dirs }}{{ $.Values.global.sharedMedia.mountPath }}/{{ . }} {{ end }}&&
      chown -R {{ .Values.global.user.uid }}:{{ .Values.global.user.gid }} {{ .Values.global.sharedMedia.mountPath }}
  securityContext:
    runAsUser: 0
  volumeMounts:
    - name: media
      mountPath: {{ .Values.global.sharedMedia.mountPath }}
{{- end -}}
