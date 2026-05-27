# AGENTS.md

Operating notes for AI agents (and humans skimming this file like one). Read this before touching anything; the [README](README.md) is for end users, this file is for contributors.

## What this repo is

A single, independent Helm chart for a REST-fronted ClamAV scanner published to GitHub Pages. **It is not a fork.** When describing the chart in commits, PRs, READMEs, or comments, never refer to "upstream" or to any other ClamAV REST helm chart by name. The strongest claim is that the chart was *inspired by* the broader ClamAV ecosystem.

If you find a reference to another ClamAV REST helm chart or the upstream Go project's GitHub URL that slipped in, strip it and reframe as independent.

## Repository layout

```
.
├── README.md                  # User-facing readme
├── CONTRIBUTING.md            # Contributor workflow
├── AGENTS.md                  # This file
├── .github/workflows/
│   └── release.yml            # chart-releaser-action → gh-pages
└── charts/
    └── clamav-rest/
        ├── Chart.yaml         # Version, appVersion, deps
        ├── values.yaml        # Source of truth for user-facing config
        ├── values.schema.json # Validates --set / -f at install time
        ├── README.md          # Auto-generatable values reference
        ├── RELEASE-NOTES.md   # One section per chart version bump
        └── templates/         # Helm templates (see below)
```

### Template responsibilities

| File | Purpose |
| --- | --- |
| `deployment.yaml` | Main scanner pod (REST + clamd as a single process tree) |
| `configmap.yaml` | All ClamAV / REST env knobs |
| `configmap-freshclam.yaml` | Optional freshclam.conf overlay |
| `secret.yaml` | Generated proxy-password + TLS Secrets (when not using existingSecret) |
| `service.yaml` | ClusterIP service (HTTP + optional HTTPS) |
| `ingress.yaml` | Optional Ingress for the HTTP port |
| `pvc.yaml` | Standalone PVC for the signature DB (keep policy enforced) |
| `hpa.yaml` | HPA v2 (CPU + memory + behavior) |
| `pdb.yaml` | PodDisruptionBudget (mutually exclusive minAvailable / maxUnavailable, enforced via `fail`) |
| `networkpolicy.yaml` | Default-deny + freshclam egress + Prometheus allow |
| `ciliumnetworkpolicy.yaml` | FQDN-locked egress for clamav.net mirrors |
| `servicemonitor.yaml` | ServiceMonitor for /metrics |
| `serviceaccount.yaml` | SA with `automountServiceAccountToken: false` by default |
| `externalsecret-image-pull.yaml` | ESO-backed dockerconfigjson Secret |
| `extra-manifests.yaml` | `tpl`-rendered extra manifests escape hatch |
| `NOTES.txt` | Post-install help text (includes `!!!`-prefixed warnings) |
| `_helpers.tpl` | Naming, label, selector, image, and secret-name helpers |

## Conventions to follow

- **Additive only.** Never remove a values key without a deprecation cycle. If something is going away, keep the key, mark it `DEPRECATED:` in the comment, and drop it in a later major version.
- **Keep defaults safe.** Default to off for anything that introduces a dependency (TLS, persistence, ingress, autoscaling, ServiceMonitor, NetworkPolicy, ExternalSecret). The chart must template cleanly with zero `--set` flags.
- **No external repo names in code or docs.** See the top section. The Docker image (`ajilaag/clamav-rest`) is the published artifact and is allowed; the GitHub source project URL is not.
- **Schema discipline.** Any new top-level or nested values key must be reflected in `values.schema.json` *and* in `values.yaml` with a `# --` comment (these comments are the source for the values table in `charts/clamav-rest/README.md`).
- **One feature, one PR.** Releases are driven by `Chart.yaml#version` bumps; mixing unrelated changes makes `RELEASE-NOTES.md` lie.
- **No comments that restate the code.** Add a comment only when the *why* is non-obvious (e.g. "PodMonitor only renders for queue + Postgres because the metrics port is wired by the worker statefulset").
- **Warn loud, fail loud.** Combinations the chart cannot honour (PDB with both minAvailable + maxUnavailable, replicaCount>1 with ReadWriteOnce persistence) either `fail` the template or emit a `!!!`-prefixed line in NOTES so install never feels silently broken.

## How to test locally

Prereqs: `helm >= 3.14`.

```bash
# Static analysis
helm lint charts/clamav-rest

# Render with defaults
helm template av charts/clamav-rest

# Render with TLS via inline cert/key
helm template av charts/clamav-rest \
  --set tls.enabled=true \
  --set tls.cert="$(cat tls.crt)" \
  --set tls.key="$(cat tls.key)"

# Render hardened production-ish config
helm template av charts/clamav-rest \
  --set tls.enabled=true \
  --set tls.existingSecret=av-tls \
  --set persistence.enabled=true \
  --set autoscaling.enabled=true \
  --set podDisruptionBudget.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set networkPolicy.enabled=true \
  --set networkPolicy.cilium=true \
  --set 'imagePullSecrets[0].name=gitlab-registry'

# Render via the consumer chart at /home/raouf/workspace/projects/clamav-api
( cd /home/raouf/workspace/projects/clamav-api/helm/clamav-api \
  && helm dependency update . \
  && helm template av . )
```

## When something looks broken

- **`fail "Set only one of …"` at install time** → the PDB block in `values.yaml` has both `minAvailable` and `maxUnavailable` set. Pick one.
- **Probes failing immediately after install** → cold start before clamd loaded the signature DB. Enable `startupProbe.enabled=true` or `persistence.enabled=true`.
- **freshclam can't reach the mirrors with `networkPolicy.enabled=true`** → make sure either the Cilium variant is on (`networkPolicy.cilium=true`) for the FQDN allow-list, or that the cluster CNI honours the vanilla NetworkPolicy DNS + egress rules.
- **`ServiceMonitor`s appear but Prometheus doesn't scrape them** → set `metrics.serviceMonitor.additionalLabels` to whatever label your Prometheus selects (commonly `release: prometheus`).
