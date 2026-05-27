# clamav-rest-helm

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/clamav-rest-api)](https://artifacthub.io/packages/search?repo=clamav-rest-api)

A single, independent Helm chart for a REST-fronted [ClamAV](https://www.clamav.net) antivirus scanner. Published to GitHub Pages from this repo. **It is not a fork.**

The chart lives at [`charts/clamav-rest`](charts/clamav-rest/) — see [its README](charts/clamav-rest/README.md) for the values reference, install instructions, and production recommendations.

## Install

```bash
helm repo add clamav-rest https://community-artifacts.github.io/clamav-rest-helm
helm repo update
helm install av clamav-rest/clamav-rest
```

## Use as a subchart

```yaml
# Chart.yaml of the consuming chart
dependencies:
  - name: clamav-rest
    version: 0.1.0
    repository: "https://community-artifacts.github.io/clamav-rest-helm"
    alias: clamav   # optional — values become .Values.clamav.*
```

Then run `helm dependency update` in the consumer chart.

## Repository layout

```
.
├── README.md                  # This file
├── AGENTS.md                  # Operating notes for AI agents
├── CONTRIBUTING.md            # Contributor workflow
├── LICENSE                    # Apache-2.0
├── .github/workflows/
│   └── release.yml            # chart-releaser → gh-pages
└── charts/
    └── clamav-rest/
        ├── Chart.yaml
        ├── values.yaml
        ├── values.schema.json
        ├── README.md
        ├── RELEASE-NOTES.md
        └── templates/
```

## Local development

```bash
# Static analysis
helm lint charts/clamav-rest

# Default render (sqlite-equivalent: no TLS, no persistence, no NetworkPolicy)
helm template av charts/clamav-rest

# Hardened render: TLS + PVC + HPA + ServiceMonitor + NetworkPolicy
helm template av charts/clamav-rest \
  --set tls.enabled=true \
  --set tls.existingSecret=av-tls \
  --set persistence.enabled=true \
  --set autoscaling.enabled=true \
  --set podDisruptionBudget.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set networkPolicy.enabled=true \
  --set networkPolicy.cilium=true
```

## License

Apache-2.0. See [`LICENSE`](LICENSE).
