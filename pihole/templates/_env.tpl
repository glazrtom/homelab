{{/* FTLCONF_misc_dnsmasq_lines needs global.domain.internal.suffix + dns.internalIP. */}}
{{- define "pihole.env" -}}
{{- include "lib.env" (dict
  "env" (dict
    "FTLCONF_dns_upstreams" .Values.dns.upstreams
    "FTLCONF_dns_listeningMode" "all"
    "FTLCONF_misc_dnsmasq_lines" (printf "address=/%s/%s" .Values.global.domain.internal.suffix .Values.dns.internalIP)
  )
) -}}
{{- end -}}
