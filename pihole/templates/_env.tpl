{{/*
FTLCONF_misc_dnsmasq_lines needs global.domain.internal.suffix + the internal ingress LB IP.
FTLCONF_webserver_api_password disables Pi-hole's own login: both hosts are already gated by Authentik
FTLCONF_webserver_api_allowedOrigins: FTL 6.8+ 403s cross-origin API writes whose Origin doesn't match
Host+scheme; the proxy hop hands Pi-hole plain http, so the https public origin must be allowed explicitly
*/}}
{{- define "pihole.env" -}}
{{- include "lib.env" (dict
  "env" (dict
    "FTLCONF_dns_upstreams" .Values.dns.upstreams
    "FTLCONF_dns_listeningMode" "all"
    "FTLCONF_misc_dnsmasq_lines" (printf "address=/%s/%s" .Values.global.domain.internal.suffix .Values.global.ingress.internal.loadBalancerIP)
    "FTLCONF_webserver_api_password" ""
    "FTLCONF_webserver_api_allowedOrigins" (printf "https://%s.%s;http://%s.%s" .Values.app.domainPrefix .Values.global.domain.public.suffix .Values.app.domainPrefix .Values.global.domain.internal.suffix)
  )
) -}}
{{- end -}}
