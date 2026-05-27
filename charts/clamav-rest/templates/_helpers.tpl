{{/*
Expand the name of the chart.
*/}}
{{- define "clamav-rest.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Truncated at 63 chars per the DNS label spec.
If the release name already contains the chart name, return it as-is so
chained releases like `clamav-rest-stage` don't end up as
`clamav-rest-stage-clamav-rest`.
*/}}
{{- define "clamav-rest.fullname" -}}
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

{{/*
Chart label value (`name-version`).
*/}}
{{- define "clamav-rest.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "clamav-rest.labels" -}}
helm.sh/chart: {{ include "clamav-rest.chart" . }}
{{ include "clamav-rest.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: scanner
app.kubernetes.io/part-of: clamav-rest
{{- end }}

{{/*
Selector labels (must stay immutable across releases — Deployment selectors).
*/}}
{{- define "clamav-rest.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clamav-rest.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name.
*/}}
{{- define "clamav-rest.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "clamav-rest.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Pinning to a digest is recommended in production — pass
`image.tag: "sha256:…"` (helm will prepend `@` automatically when the tag
starts with `sha256:`).
*/}}
{{- define "clamav-rest.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- if hasPrefix "sha256:" $tag -}}
{{ .Values.image.repository }}@{{ $tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ $tag }}
{{- end -}}
{{- end }}

{{/*
Resolved image-pull-secrets list. Combines the explicit
`.Values.imagePullSecrets` with the ExternalSecret-managed dockerconfigjson
when `imageRepositoryCredential.create=true`.
*/}}
{{- define "clamav-rest.imagePullSecrets" -}}
{{- $secrets := list -}}
{{- range .Values.imagePullSecrets -}}
{{- $secrets = append $secrets (dict "name" .name) -}}
{{- end -}}
{{- if and .Values.imageRepositoryCredential.create .Values.imageRepositoryCredential.name -}}
{{- $secrets = append $secrets (dict "name" .Values.imageRepositoryCredential.name) -}}
{{- end -}}
{{- if $secrets -}}
{{- toYaml $secrets -}}
{{- end -}}
{{- end }}

{{/*
Proxy secret name — either the user-supplied existingSecret or the chart's
generated `<fullname>-proxy` Secret.
*/}}
{{- define "clamav-rest.proxySecretName" -}}
{{- if .Values.proxy.existingSecret -}}
{{ .Values.proxy.existingSecret }}
{{- else -}}
{{ include "clamav-rest.fullname" . }}-proxy
{{- end -}}
{{- end }}

{{/*
TLS secret name.
*/}}
{{- define "clamav-rest.tlsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{ .Values.tls.existingSecret }}
{{- else -}}
{{ include "clamav-rest.fullname" . }}-tls
{{- end -}}
{{- end }}

{{/*
freshclam ConfigMap name.
*/}}
{{- define "clamav-rest.freshclamConfigMapName" -}}
{{- if .Values.freshclamConfig.existingConfigMap -}}
{{ .Values.freshclamConfig.existingConfigMap }}
{{- else -}}
{{ include "clamav-rest.fullname" . }}-freshclam
{{- end -}}
{{- end }}
