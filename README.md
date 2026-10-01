# bioc-webr

Build [WebAssembly](https://webassembly.org) binaries of Bioconductor packages
for [webR](https://docs.r-wasm.org/webr/latest/), and publish them as a
CRAN-like repository that a browser can install from. Published releases are
served at `https://webr.bioconductor.org/<release>`, from the Kubernetes
templates in [`deploy/`](deploy/).

Anyone running webR, in a web page, a Quarto `live-html` document or a browser
console, can install Bioconductor packages from these repositories;
[docs/examples/](docs/examples/) shows how.

```bash
cp .env.example .env          # set BIOC_VERSION
docker compose run --rm build
docker compose run --rm verify
scripts/publish.sh            # also needs RCLONE_REMOTE and RCLONE_CONFIG_DIR
```

The [reusable workflow](.github/workflows/build.yml) runs the same `build`
service in CI and stops after it; see [Status](#status).

## What this produces

A directory tree laid out like a CRAN repository, with WebAssembly binaries
where the platform binaries would normally be:

```
<bioc-version>/
├── src/contrib/                        source tarballs
├── bin/emscripten/contrib/<r-version>/ .tgz WebAssembly binaries + PACKAGES
├── index.html                          browsable listing
├── pathlist                            every file, one path per line
└── BUILDINFO                           what produced this tree
```

Published under a version prefix, so releases sit alongside each other:

```
<RCLONE_REMOTE>/3.23/...    served as https://webr.bioconductor.org/3.23/...
<RCLONE_REMOTE>/3.24/...    served as https://webr.bioconductor.org/3.24/...
```

## Requirements

- Docker with Compose v2 (`docker compose`, not `docker-compose`)
- Disk: a full release is tens of gigabytes
- Memory: 8 GB or more. Emscripten link steps are the memory-hungry part, and
  the failure mode is an opaque OOM kill
- To publish: an `rclone.conf` for the object store, with `RCLONE_REMOTE` and
  `RCLONE_CONFIG_DIR` set in `.env`
  ([docs/operations.md](docs/operations.md#configuration))

Nothing else. No local R, no Emscripten toolchain — the webR image carries both.
The hosting has its own requirements, listed in
[docs/deployment.md](docs/deployment.md#hosting).

## Documentation

| | |
|---|---|
| [docs/README.md](docs/README.md) | Page map and quick facts |
| [docs/development.md](docs/development.md) | **Start here to work on this.** Setup, the fast iteration loop, how to test a change without a multi-hour build |
| [docs/architecture.md](docs/architecture.md) | What each piece of the build and the hosting does and why, including the design decisions that are not obvious |
| [docs/deployment.md](docs/deployment.md) | Running builds in CI or on a build host, and deploying the hosting from `deploy/` |
| [docs/operations.md](docs/operations.md) | Release cadence, publishing, hosting health checks, serving a new release, recovery |
| [docs/updating.md](docs/updating.md) | Update procedures and cadence: Bioconductor releases, webR, images, GitHub Actions, the cluster |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → cause → fix |
| [docs/security.md](docs/security.md) | What the credentials grant, the hosting's trust boundaries, and what a compiled package repository means as a supply chain |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to make a change here |
| [demo/](demo/) | A self-contained page that installs Bioconductor packages into a browser and runs R. Not deployed |
| [docs/examples/](docs/examples/) | Production configurations, and using the repository from webR |

## Status

- Bioconductor 3.23 is built with this stack and published: a full release of
  2239 WebAssembly binaries. Releases 3.18 to 3.22 are served from the same
  hosting and carry no `BUILDINFO`.
- The templates in `deploy/` match the running hosting. Their known
  limitations are listed in
  [docs/deployment.md](docs/deployment.md#known-limitations).
- The reusable workflow stops at its Summarise step after the build, so it
  neither validates nor publishes; see
  [docs/deployment.md](docs/deployment.md#the-reusable-workflow).
- [docs/examples/](docs/examples/) says which ways of using the repository have
  been run in a browser and which are written from webR's documented interface.
- **Which Bioconductor packages work under webR is unknown.** A wasm build can
  succeed and the package still be unusable in a browser — anything wanting
  threads, sockets, subprocesses or a real filesystem may compile and then fail
  at runtime. Nothing here tests that.

## License

MIT. See [LICENSE](LICENSE).
