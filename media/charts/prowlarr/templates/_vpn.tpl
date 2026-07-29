{{/* gluetun sidecar; prowlarr's traffic egresses through the VPN. */}}
{{- define "prowlarr.vpnContainer" -}}
- name: vpn
  image: {{ .Values.vpn.image }}
  imagePullPolicy: {{ .Values.global.imagePullPolicy }}
  securityContext:
    capabilities:
      add:
        - NET_ADMIN
  env:
    - name: VPN_SERVICE_PROVIDER
      value: {{ .Values.vpn.env.VPN_SERVICE_PROVIDER | quote }}
    - name: VPN_TYPE
      value: {{ .Values.vpn.env.VPN_TYPE | quote }}
    - name: OPENVPN_USER
      valueFrom:
        secretKeyRef:
          name: {{ .Values.vpn.env.OPENVPN_SECRET_NAME }}
          key: {{ .Values.vpn.env.OPENVPN_SECRET_USER_KEY }}
    - name: OPENVPN_PASSWORD
      valueFrom:
        secretKeyRef:
          name: {{ .Values.vpn.env.OPENVPN_SECRET_NAME }}
          key: {{ .Values.vpn.env.OPENVPN_SECRET_PASSWORD_KEY }}
    - name: SERVER_REGIONS
      value: {{ .Values.vpn.env.SERVER_REGIONS | quote }}
    - name: DNS_KEEP_NAMESERVER
      value: {{ .Values.vpn.env.DNS_KEEP_NAMESERVER | quote }}
    - name: FIREWALL_OUTBOUND_SUBNETS
      value: {{ .Values.vpn.env.FIREWALL_OUTBOUND_SUBNETS | quote }}
{{- end -}}
