{{- define "derper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "derper.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "derper.headless" -}}
{{- printf "%s-mesh" (include "derper.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "derper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "derper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "derper.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "derper.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "derper.hostname" -}}
{{- required "hostname is required" .Values.hostname }}
{{- end }}

{{- define "derper.validate" -}}
{{- if and .Values.ingress.enabled .Values.tls.enabled }}
{{- fail "ingress.enabled needs tls.enabled=false: the ingress terminates TLS and the pods serve plain HTTP" }}
{{- end }}
{{- end }}

{{- define "derper.meshEnabled" -}}
{{- if gt (int .Values.replicaCount) 1 }}true{{ end }}
{{- end }}

{{- define "derper.meshSecret" -}}
{{- default (printf "%s-mesh" (include "derper.fullname" .)) .Values.mesh.existingSecret }}
{{- end }}

{{/* -mesh-with: every pod, addressed through the headless Service. Over TLS the URL keeps `hostname` for SNI and dials the pod. */}}
{{- define "derper.meshWith" -}}
{{- $entries := list }}
{{- $full := include "derper.fullname" . }}
{{- $svc := printf "%s.%s.svc.%s" (include "derper.headless" .) .Release.Namespace .Values.clusterDomain }}
{{- range $i := until (int .Values.replicaCount) }}
{{- $pod := printf "%s-%d.%s" $full $i $svc }}
{{- if $.Values.tls.enabled }}
{{- $entries = append $entries (printf "https://%s:%d/derp|%s" (include "derper.hostname" $) (int $.Values.ports.derp) $pod) }}
{{- else }}
{{- $entries = append $entries (printf "http://%s:%d/derp" $pod (int $.Values.ports.derp)) }}
{{- end }}
{{- end }}
{{- join "," $entries }}
{{- end }}

{{/* derper's manual cert mode reads <certdir>/<hostname>.crt|.key, with these characters stripped. */}}
{{- define "derper.certName" -}}
{{- regexReplaceAll "[^a-zA-Z0-9\\-\\.]" (include "derper.hostname" .) "" }}
{{- end }}

{{- define "derper.tlsSecret" -}}
{{- if .Values.tls.certManager.enabled }}
{{- printf "%s-tls" (include "derper.fullname" .) }}
{{- else }}
{{- required "tls.secretName is required when tls.enabled and certManager is off" .Values.tls.secretName }}
{{- end }}
{{- end }}

{{- define "derper.caSecret" -}}
{{- if .Values.tls.ca.secretName }}{{ .Values.tls.ca.secretName }}
{{- else if .Values.tls.certManager.enabled }}{{ include "derper.tlsSecret" . }}
{{- end }}
{{- end }}

{{/* Relay host and ports clients connect to, as written into the DERP map. */}}
{{- define "derper.publicHost" -}}
{{- if .Values.derpMap.hostName }}{{ .Values.derpMap.hostName }}
{{- else if .Values.ingress.enabled }}{{ default (include "derper.hostname" .) .Values.ingress.host }}
{{- else }}{{ include "derper.hostname" . }}
{{- end }}
{{- end }}

{{- define "derper.publicTLS" -}}
{{- if .Values.ingress.enabled }}{{ if .Values.ingress.tls.enabled }}true{{ end }}
{{- else if .Values.tls.enabled }}true
{{- end }}
{{- end }}

{{- define "derper.publicDerpPort" -}}
{{- if .Values.derpMap.derpPort }}{{ .Values.derpMap.derpPort }}
{{- else if .Values.ingress.enabled }}{{ ternary 443 80 .Values.ingress.tls.enabled }}
{{- else if eq .Values.service.type "NodePort" }}{{ required "service.nodePorts.derp or derpMap.derpPort is required for NodePort" .Values.service.nodePorts.derp }}
{{- else }}{{ .Values.service.derpPort }}
{{- end }}
{{- end }}

{{- define "derper.publicStunPort" -}}
{{- if .Values.derpMap.stunPort }}{{ .Values.derpMap.stunPort }}
{{- else if .Values.ingress.enabled }}
{{- if eq .Values.stunService.type "NodePort" }}{{ required "stunService.nodePort or derpMap.stunPort is required for NodePort" .Values.stunService.nodePort }}
{{- else }}{{ .Values.stunService.port }}{{ end }}
{{- else if eq .Values.service.type "NodePort" }}{{ required "service.nodePorts.stun or derpMap.stunPort is required for NodePort" .Values.service.nodePorts.stun }}
{{- else }}{{ .Values.service.stunPort }}
{{- end }}
{{- end }}

{{- define "derper.probe" -}}
{{- if .Values.tls.enabled }}
tcpSocket:
  port: derp
{{- else }}
httpGet:
  path: /derp/probe
  port: derp
{{- end }}
{{- end }}
