{{- define "wordpress-mysql.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "wordpress-mysql.fullname" -}}
{{- printf "%s-%s" (include "wordpress-mysql.name" .) .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "wordpress-mysql.labels" -}}
app.kubernetes.io/name: {{ include "wordpress-mysql.name" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
