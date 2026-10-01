# Documentation

Maintainer documentation for the Bioconductor webR binaries: the build that
compiles Bioconductor releases to WebAssembly, and the hosting that serves them.

## Quick facts

| | |
|---|---|
| Package repositories | `https://webr.bioconductor.org/<release>`, releases 3.18 to 3.23 |
| Console page | `https://run.webr.bioconductor.org/`; does not start ([known limitations](deployment.md#known-limitations)) |
| Build | The Docker Compose stack in this repository, on a build host or through the reusable workflow |
| Published to | Jetstream2 object storage, `js2:/webr/<release>` |
| Served from | k3s with Traefik and cert-manager, namespaces `webr` and `webr-repl`, templates in [`deploy/`](../deploy/) |
| webR for new builds | `v0.6.0`, R 4.6: Bioconductor 3.23 and 3.24 |
| Depends on | bioconductor.org sources, the `ghcr.io/r-wasm/webr` image, object storage, Posit Package Manager and Docker Hub at server start, `webr.r-wasm.org` |

## Pages

| Page | Covers |
|---|---|
| [architecture.md](architecture.md) | The build and the hosting: components, data flow, state, external dependencies |
| [development.md](development.md) | Setting up, the subset-build loop, changing the scripts |
| [deployment.md](deployment.md) | Running builds in CI or on a build host; deploying the hosting from `deploy/`; known limitations |
| [operations.md](operations.md) | Release builds, publishing, health checks, serving a new release, backups and recovery |
| [updating.md](updating.md) | Update procedures and cadence for every moving part |
| [troubleshooting.md](troubleshooting.md) | Symptom, cause, fix |
| [security.md](security.md) | Trust boundaries, secrets, hardening, reporting a vulnerability |
| [examples/](examples/) | Production configurations, and using the repository from webR |
