# clamav-rest

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](../../LICENSE)
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/clamav-rest-api)](https://artifacthub.io/packages/search?repo=clamav-rest-api)

Production-oriented Helm chart for a REST-fronted [ClamAV](https://www.clamav.net/) antivirus scanner. The chart is opinionated about defaults that matter in real clusters (RollingUpdate with maxUnavailable=0, config-checksum pod restarts, secret-backed proxy passwords, FQDN-locked egress when Cilium is in play) and stays additive on the rest.

## TL;DR

```bash
helm repo add clamav-rest https://community-artifacts.github.io/clamav-rest-helm
helm repo update
helm install av clamav-rest/clamav-rest
```

Or as a dependency from a sibling chart:

```yaml
# Chart.yaml of the consuming chart
dependencies:
  - name: clamav-rest
    version: 0.1.0
    repository: "https://community-artifacts.github.io/clamav-rest-helm"
    alias: clamav
```

## Features

| Concern | Status | Knob |
| --- | --- | --- |
| HTTP scan API on `:9000` | ✅ default | `config.port` |
| HTTPS scan API on `:9443` | opt-in | `tls.enabled`, `tls.{cert,key}` or `tls.existingSecret` |
| Prometheus `/metrics` | ✅ exposed by the image | `metrics.serviceMonitor.enabled` for the ServiceMonitor |
| Signature DB persistence | opt-in | `persistence.enabled` (PVC at `/clamav/data`) |
| `freshclam.conf` overlay | opt-in | `freshclamConfig.enabled` + `.config` or `.existingConfigMap` |
| Forward proxy for freshclam | opt-in | `proxy.*` (password via Secret) |
| HPA (CPU + memory) | opt-in | `autoscaling.enabled` |
| PDB | opt-in | `podDisruptionBudget.enabled` |
| Vanilla NetworkPolicy | opt-in | `networkPolicy.enabled` + `.vanilla` |
| CiliumNetworkPolicy (DNS + FQDN egress) | opt-in | `networkPolicy.enabled` + `.cilium` |
| ESO-backed image-pull credential | opt-in | `imageRepositoryCredential.create` |
| Arbitrary extra manifests | opt-in | `extraManifests` |

## Endpoints

The chart exposes the image's REST surface on the `http` (and optionally `https`) port. Documented endpoints:

| Path | Method | Purpose |
| --- | --- | --- |
| `/` | GET | Process stats — used as the default probe target |
| `/version` | GET | ClamAV binary + signature DB versions |
| `/metrics` | GET | Prometheus metrics |
| `/v2/scan` | POST | Scan multipart files (current API) |
| `/scanFile` | GET | Scan a single file by path |
| `/scanPath` | GET | Scan a directory recursively |
| `/scanHandlerBody` | POST | Scan an arbitrary request body |
| `/scan` | POST | Deprecated; use `/v2/scan` |

## Probes & cold-start

The image has no dedicated `/healthz`. The chart probes `/`, which only returns 200 once `clamd` has loaded the signature database. On a cold pod (no PVC, no warm cache) that takes 30–120 s depending on the freshclam mirror. Two operational levers:

1. Enable `persistence.enabled=true` to reuse the signature DB across restarts.
2. Enable `startupProbe.enabled=true` to decouple cold-start tolerance from `livenessProbe`.

## Production recommendations

- **Pin the image.** `image.tag` defaults to `latest` (matching `appVersion`). Switch to a versioned tag or `sha256:…` digest before going to production. The helper accepts a `sha256:` prefix and emits `repository@sha256:…`.
- **Never inline proxy passwords.** Use `proxy.existingSecret` and reference an out-of-band Secret. Inline `proxy.password` ends up in the rendered manifests, the Helm release history, and the GitOps diff.
- **Set a PDB once you scale past 1.** RollingUpdate handles voluntary disruption fine; PDB protects against node drains.
- **Wire a NetworkPolicy.** Default-deny is the only correct stance for an in-cluster scanner; turn on `networkPolicy.enabled` and let the chart open just the freshclam egress + the scrape ingress.
- **Tune `resources.limits.memory` to your largest expected file.** clamd materialises the signature DB in memory (~1.5 GiB) and adds per-scan overhead — under-provisioning shows up as OOMKilled mid-scan.

## Values reference

Run `helm show values .` for the canonical, comment-annotated source. Highlights:

```yaml
replicaCount: 2

image:
  repository: ajilaag/clamav-rest
  tag: ""              # defaults to .Chart.AppVersion (`latest`) — pin in prod

config:
  port: 9000
  sslPort: 9443
  maxFileSize: "25M"
  signatureChecks: 2
  timezone: "Europe/Zurich"

tls:
  enabled: false       # set true + existingSecret (or cert/key) for HTTPS

persistence:
  enabled: false       # PVC at /clamav/data — keep the signature DB warm

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

metrics:
  serviceMonitor:
    enabled: false     # requires the Prometheus Operator

networkPolicy:
  enabled: false
  vanilla: true
  cilium: false        # also render a CiliumNetworkPolicy

podDisruptionBudget:
  enabled: false
  minAvailable: 1
```

## License

Apache-2.0. See [`LICENSE`](../../LICENSE).
