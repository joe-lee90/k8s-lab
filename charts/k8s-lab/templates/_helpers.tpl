{{/*
Base name for all resources. Truncated to 63 characters because that is the
maximum length of a Kubernetes label value and a DNS label.
*/}}
{{- define "k8s-lab.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified name: <release>-<chart>. This prefix is what allows two
releases of this chart to coexist in one namespace without colliding.
*/}}
{{- define "k8s-lab.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "k8s-lab.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Labels applied to every object. app.kubernetes.io/* are the standard
Kubernetes recommended labels -- tooling (including Argo CD in Stage 9)
reads these to group and display resources.
*/}}
{{- define "k8s-lab.labels" -}}
app.kubernetes.io/name: {{ include "k8s-lab.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}