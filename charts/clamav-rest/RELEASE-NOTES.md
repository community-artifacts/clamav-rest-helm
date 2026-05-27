# Release notes

## 0.1.0 — 2026-05-27

Initial release.

### Added
- Deployment for a REST-fronted ClamAV scanner (`ajilaag/clamav-rest` by default).
- ConfigMap with the full set of documented env knobs (`MAX_*`, `PCRE_*`, `SIGNATURE_CHECKS`, `ALLOW_ORIGINS`, `TZ`).
- Optional TLS: inline `tls.cert`/`tls.key` or `tls.existingSecret`. Service exposes `https` only when enabled.
- Optional freshclam config overlay (`freshclamConfig.config` or `existingConfigMap`) mounted over `/clamav/etc/freshclam.conf`.
- Optional PVC for `/clamav/data` (with `helm.sh/resource-policy: keep` so the signature DB survives `helm uninstall`).
- Optional forward-proxy support for freshclam (`proxy.*`), with password handled through a Secret (`proxy.existingSecret` recommended).
- ServiceMonitor for the image's `/metrics` endpoint.
- HPA v2 with CPU + memory targets and a custom `behavior` block.
- PodDisruptionBudget (mutually exclusive `minAvailable` / `maxUnavailable`).
- Vanilla NetworkPolicy with default-deny + freshclam egress + Prometheus scrape allow rule.
- CiliumNetworkPolicy with FQDN-locked egress for `*.clamav.net`.
- ExternalSecret rendering a `dockerconfigjson` image-pull credential from Vault (off by default).
- `extraManifests` escape hatch for arbitrary additional resources (templated against `.`).

### Security defaults
- Pod runs as the image's `clamav` user (`runAsUser: 100`, `runAsGroup: 101`, `runAsNonRoot: true`).
- All capabilities dropped; `allowPrivilegeEscalation: false`.
- ServiceAccount has `automountServiceAccountToken: false` — the workload does not call the Kubernetes API.
- Config checksum annotation forces pod restart on ConfigMap change.

### Known gaps
- No dedicated `/healthz` probe — probes hit `/` which returns 200 only after the signature DB is loaded. `startupProbe.enabled=true` is the recommended cold-start workaround when `persistence.enabled=false`.
- `metrics.serviceMonitor.scheme=https` reuses the `https` Service port and requires both `tls.enabled=true` and a non-empty `tlsConfig`.
