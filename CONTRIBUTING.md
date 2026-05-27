# Contributing

Thanks for taking the time to contribute. Read [`AGENTS.md`](AGENTS.md) first — it covers the layout and the non-obvious conventions.

## Workflow

1. **Open an issue first** for anything bigger than a typo / one-liner. Helps avoid wasted work on changes that won't land.
2. **One feature, one PR.** Releases are cut from `Chart.yaml#version` bumps; mixing unrelated changes makes `RELEASE-NOTES.md` lie.
3. **Bump the chart version** in `charts/clamav-rest/Chart.yaml` for every user-visible change (templates, defaults, schema, docs that drive behaviour). Patch for fixes, minor for additive features, major for any breaking change.
4. **Add a `RELEASE-NOTES.md` entry** mirroring the `Chart.yaml#annotations.artifacthub.io/changes` block.
5. **Update `values.schema.json`** alongside any new or renamed values key.
6. **Update `values.yaml` comments** — the `# --` comments drive the generated values table in the chart README.

## Testing locally

```bash
helm lint charts/clamav-rest
helm template av charts/clamav-rest > /tmp/default.yaml
helm template av charts/clamav-rest -f tests/values-hardened.yaml > /tmp/hardened.yaml
```

Compare renders against the previous release tarball when changing existing templates:

```bash
helm repo add clamav-rest https://community-artifacts.github.io/clamav-rest-helm
helm pull clamav-rest/clamav-rest --version <prev>
tar -xzf clamav-rest-<prev>.tgz -C /tmp/prev
helm template av /tmp/prev/clamav-rest > /tmp/prev.yaml
diff /tmp/prev.yaml /tmp/default.yaml
```

## Coding style

- **No comments that restate the code.** Templates are noisy enough.
- **Keep defaults safe.** Default-off for anything that introduces a dependency (TLS, persistence, ingress, ServiceMonitor, NetworkPolicy, ExternalSecret).
- **Fail loud, not silent.** Combinations the chart cannot honour either `fail` the template or emit a `!!!`-prefixed line in `NOTES.txt`.
- **No external repo names.** The Docker image name is fine; GitHub source project URLs are not. Frame the chart as independent.

## Commit messages

Conventional commits are encouraged but not enforced. The body matters more than the prefix.

## License

By contributing you agree to license your work under Apache-2.0 (see [`LICENSE`](LICENSE)).
