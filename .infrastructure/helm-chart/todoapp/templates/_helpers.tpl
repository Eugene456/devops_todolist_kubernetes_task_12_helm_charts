{{- define "todoapp.serviceAccountName" -}}
{{ .Chart.Name }}-{{ .Values.serviceAccount.name }}
{{- end }}