{{/*
FTLCONF_misc_dnsmasq_lines needs global.domain.internal.suffix + the internal ingress LB IP.
FTLCONF_webserver_api_password disables Pi-hole's own login: both hosts are already gated by Authentik
*/}}
{{- define "pihole.env" -}}
{{- include "lib.env" (dict
  "env" (dict
    "FTLCONF_dns_upstreams" .Values.dns.upstreams
    "FTLCONF_dns_listeningMode" "all"
    "FTLCONF_misc_dnsmasq_lines" (printf "address=/%s/%s" .Values.global.domain.internal.suffix .Values.global.ingress.internal.loadBalancerIP)
    "FTLCONF_webserver_api_password" ""
  )
) -}}
{{- end -}}
