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

{{/* Per-node helpers take (dict "root" $ "node" $node). */}}

{{- define "derper.nodeSelectorLabels" -}}
{{ include "derper.selectorLabels" .root }}
derper.coder.com/node: {{ .node.name | quote }}
{{- end }}

{{- define "derper.nodeLabels" -}}
{{ include "derper.labels" .root }}
derper.coder.com/node: {{ .node.name | quote }}
{{- end }}

{{- define "derper.nodeFullname" -}}
{{- printf "%s-%s" (include "derper.fullname" .root) .node.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "derper.validate" -}}
{{- $v := .Values }}
{{- if not $v.nodes }}
{{- fail "nodes needs at least one entry with name and hostname" }}
{{- end }}
{{- $names := dict }}
{{- range $v.nodes }}
{{- if not (and .name .hostname) }}
{{- fail "each entry in nodes needs name and hostname" }}
{{- end }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" .name) }}
{{- fail (printf "nodes: name %q must be a DNS label" .name) }}
{{- end }}
{{- if hasKey $names .name }}
{{- fail (printf "nodes: name %q is used twice" .name) }}
{{- end }}
{{- $_ := set $names .name true }}
{{- end }}
{{- if not (has $v.derpMap.layout (list "region-per-node" "single-region")) }}
{{- fail "derpMap.layout must be region-per-node or single-region" }}
{{- end }}
{{- if and $v.ingress.enabled $v.tls.enabled }}
{{- fail "ingress.enabled needs tls.enabled=false: the ingress terminates TLS and the pods serve plain HTTP" }}
{{- end }}
{{- if and (include "derper.meshEnabled" .) (not (include "derper.publicTLS" .)) }}
{{- fail "meshing (derpMap.layout=single-region with more than one node) needs TLS in the pods or at the ingress: derper meshes over HTTPS only" }}
{{- end }}
{{- end }}

{{/* Nodes mesh only when they share a region: across regions, clients connect to the peer's home region directly. */}}
{{- define "derper.meshEnabled" -}}
{{- if and (eq .Values.derpMap.layout "single-region") (gt (len .Values.nodes) 1) }}true{{ end }}
{{- end }}

{{- define "derper.meshSecret" -}}
{{- default (printf "%s-mesh" (include "derper.fullname" .)) .Values.mesh.existingSecret }}
{{- end }}

{{/*
-mesh-with: one entry per node, "<host>[:port]/<dial host>". The URL host is
used for TLS verification and the dial host for the connection. With TLS in
the pods, dial the node's Service; behind an ingress, dial the ingress.
*/}}
{{- define "derper.meshWith" -}}
{{- $root := . }}
{{- $entries := list }}
{{- range .Values.nodes }}
{{- $ctx := dict "root" $root "node" . }}
{{- if $root.Values.tls.enabled }}
{{- $port := int $root.Values.service.derpPort }}
{{- $host := ternary .hostname (printf "%s:%d" .hostname $port) (eq $port 443) }}
{{- $svc := printf "%s.%s.svc.%s" (include "derper.nodeFullname" $ctx) $root.Release.Namespace $root.Values.clusterDomain }}
{{- $entries = append $entries (printf "%s/%s" $host $svc) }}
{{- else if $root.Values.mesh.ingressDialHost }}
{{- $entries = append $entries (printf "%s/%s" .hostname $root.Values.mesh.ingressDialHost) }}
{{- else }}
{{- $entries = append $entries .hostname }}
{{- end }}
{{- end }}
{{- join "," $entries }}
{{- end }}

{{/* derper's manual cert mode reads <certdir>/<hostname>.crt|.key, with these characters stripped. */}}
{{- define "derper.certName" -}}
{{- regexReplaceAll "[^a-zA-Z0-9\\-\\.]" .node.hostname "" }}
{{- end }}

{{- define "derper.nodeTLSSecret" -}}
{{- if .node.tlsSecretName }}{{ .node.tlsSecretName }}
{{- else if .root.Values.tls.certManager.enabled }}{{ printf "%s-tls" (include "derper.nodeFullname" .) }}
{{- else }}{{ required "tls.secretName or nodes[].tlsSecretName is required when tls.enabled and certManager is off" .root.Values.tls.secretName }}
{{- end }}
{{- end }}

{{- define "derper.nodeIngressTLSSecret" -}}
{{- if .node.tlsSecretName }}{{ .node.tlsSecretName }}
{{- else }}{{ required "ingress.tls.secretName or nodes[].tlsSecretName is required when ingress.tls.enabled" .root.Values.ingress.tls.secretName }}
{{- end }}
{{- end }}

{{/* CA the pods trust for mesh connections. */}}
{{- define "derper.nodeCASecret" -}}
{{- if .root.Values.tls.ca.secretName }}{{ .root.Values.tls.ca.secretName }}
{{- else if and .root.Values.tls.enabled .root.Values.tls.certManager.enabled }}{{ include "derper.nodeTLSSecret" . }}
{{- end }}
{{- end }}

{{- define "derper.publicTLS" -}}
{{- if .Values.ingress.enabled }}{{ if .Values.ingress.tls.enabled }}true{{ end }}
{{- else if .Values.tls.enabled }}true
{{- end }}
{{- end }}

{{/* Relay port clients connect to, as written into the DERP map. */}}
{{- define "derper.nodePublicDerpPort" -}}
{{- $v := .root.Values }}
{{- if $v.derpMap.derpPort }}{{ $v.derpMap.derpPort }}
{{- else if $v.ingress.enabled }}{{ ternary 443 80 $v.ingress.tls.enabled }}
{{- else if eq $v.service.type "NodePort" }}{{ required (printf "nodes[%s].nodePorts.derp or derpMap.derpPort is required for NodePort" .node.name) (dig "nodePorts" "derp" "" .node) }}
{{- else }}{{ $v.service.derpPort }}
{{- end }}
{{- end }}

{{- define "derper.nodePublicStunPort" -}}
{{- $v := .root.Values }}
{{- if $v.derpMap.stunPort }}{{ $v.derpMap.stunPort }}
{{- else if $v.ingress.enabled }}
{{- if eq $v.stunService.type "NodePort" }}{{ required "stunService.nodePort or derpMap.stunPort is required for NodePort" $v.stunService.nodePort }}
{{- else }}{{ $v.stunService.port }}{{ end }}
{{- else if eq $v.service.type "NodePort" }}{{ required (printf "nodes[%s].nodePorts.stun or derpMap.stunPort is required for NodePort" .node.name) (dig "nodePorts" "stun" "" .node) }}
{{- else }}{{ $v.service.stunPort }}
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
