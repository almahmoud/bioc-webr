# Architecture

This repository builds WebAssembly package repositories for Bioconductor
releases and holds the templates that serve them. [Hosting](#hosting) covers
the serving side.

## What the build is

One input — a Bioconductor release number — and one output: a CRAN-like
repository whose binaries are WebAssembly instead of native code.

```
BIOC_VERSION=3.23
      │
      ▼
https://bioconductor.org/packages/3.23/bioc/     source packages
      │
      │  rwasm, driving Emscripten inside the r-wasm/webr image
      ▼
/repo/3.23/_site/                                named Docker volume
  ├── src/contrib/                               source tarballs
  ├── bin/emscripten/contrib/4.6/                .tgz wasm binaries + PACKAGES
  ├── pathlist                                   every file, one per line
  ├── index.html                                 browsable listing
  └── BUILDINFO                                  provenance
      │
      │  verify  →  rclone sync
      ▼
<RCLONE_REMOTE>/3.23/                            object storage, e.g. js2:/webr/3.23/
```

The `bin/emscripten/contrib/<r-version>/` path is what makes this a repository
rather than a pile of files: webR's `install.packages()` looks there, exactly
as native R looks in `bin/macosx/...` or `bin/windows/...`.

## The services

`compose.yaml` defines five. Only `build` and `verify` run by default; the rest
sit behind profiles.

| Service | Image | Does |
|---|---|---|
| `build` | `ghcr.io/r-wasm/webr` | Cross-compiles the release, then generates the index |
| `verify` | `debian:12-slim` | Decides whether the result is publishable |
| `export` | `debian:12-slim` | Copies the tree onto the host, for inspection |
| `serve` | `nginx` | Serves it over HTTP, for testing from a webR session |
| `publish` | `rclone/rclone` | `rclone sync` to the object store |

**All the logic lives in `scripts/`.** `compose.yaml` only wires things up.
Nothing important is written as a compose `command:` string, because those
cannot be linted, tested, or read comfortably.

## Design decisions

### The repository is built in a named volume, not in `./out`

rwasm creates directories with `fs::dir_create()`, which creates the directory
and then chmods it, and on a Docker Desktop bind mount from macOS that chmod
fails. The directory is created mode `0545` and the fix-up returns
`EACCES`:

```
Error: [EACCES] Failed to set permissions for directory '/site/src': permission denied
```

Base R's `dir.create()` on the same path succeeds, and on Linux a bind mount
is a real filesystem where both work. A named volume is backed by the Linux
VM's own filesystem on every platform, so it works everywhere.

The volume also gives the build these properties:

- **It persists between runs.** rwasm skips any package already listed in the
  binary `PACKAGES` index at the same version, and reuses source tarballs it
  has already downloaded. It rewrites the index at the end of a run, and only
  when that run downloaded at least one source tarball. When a package's
  version changes, it deletes the old source tarball but keeps the old binary.
  [operations.md](operations.md#re-running-a-build) covers what both mean for
  a re-run.
- **Publishing never needs a host copy.** `verify` and `publish` read the
  volume directly. For a tens-of-gigabytes release, not copying is worth
  something.
- `export` exists for when you do want the files on the host, and copies
  *without* preserving modes — restoring them is the operation that fails.

### The container runs as root and chowns on the way out

Overriding `user:` would be tidier-looking, but the image's R library paths and
`HOME` are set up for root, so a non-root run needs `R_LIBS_USER` redirected and
a writable `HOME` before anything installs. Chowning the logs on exit is less
machinery and fewer assumptions about an image this repository does not
control. The logs and the built tree come back owned by `HOST_UID`:`HOST_GID`.

### Verification runs in a container, not on the host

`scripts/verify_site.sh` could run on the host — the tree can be exported. It
does not, for two reasons:

1. The tree lives in a volume. Checking it on the host would mean exporting
   tens of gigabytes first, purely to count files.
2. The checks use GNU `find`, `grep` and `stat`. A maintainer on macOS would
   otherwise run the BSD versions against a tree built by the GNU ones — and
   `grep -c`, `find -path` and `stat` all differ in ways that would make the
   check quietly wrong rather than loudly broken.

### Publishing is gated

`rclone sync` **deletes remote files that are absent locally.** Publishing a
half-built tree does not merely fail to add packages — it destroys the working
repository already published under that version.

The gate:

- The `publish` service's default command is `version`. Running it directly does
  nothing.
- `scripts/publish.sh` runs `verify` first and refuses on failure.
- `--force` exists, and requires typing the version number to confirm.
- A subset build writes an `INCOMPLETE` marker that `verify` fails on.

### The reusable workflow contains no build logic

`.github/workflows/build.yml` writes a `.env`, runs
`docker compose run --rm build`, and calls the same `verify` and `publish`
scripts a developer runs. There is no CI-only path, because a CI-only path
drifts.

If you find yourself adding a build step to the workflow that has no equivalent
in `compose.yaml`, that is the signal it belongs in `scripts/`.

### rwasm's bundled remotes are filtered

rwasm ships a list of GitHub references to packages patched to compile for
WebAssembly (`inst/webr-remotes`, 17 entries), and `prefer_remotes()` swaps
those sources in during a build.

Two upstream problems, both hit with the versions in webR v0.6.0
(rwasm 0.3.0.9000, pkgdepends 0.9.1):

1. **Three references fail to resolve** — `cran/mmrm@0.2.2`, `r-wasm/TMB@webr`,
   `r-wasm/rigraph@webr` — all with `nrow(out) must equal 1`. The repositories,
   refs and DESCRIPTION files exist and are reachable, so this is a resolution
   incompatibility, not a dead reference. (`rigraph`'s DESCRIPTION declares
   `Package: igraph`; repository and package names differ.) Because
   `prefer_remotes()` resolves the list as a batch, one bad reference aborts
   the whole build before a single package compiles.

2. **The documented escape hatch does not work.** `remotes=` is documented as
   taking "a character vector of package references", but `prefer_remotes()`
   opens with `if (is.na(remotes))`, which on a vector of length > 1 is an
   error rather than a test. In practice the parameter accepts only `NA` or
   `NULL`.

So `build_repo.R` resolves each reference individually, writes the working
subset back over rwasm's bundled file, and passes `NA` so rwasm reads it through
its own code path. The edit stays in the disposable container: rwasm lives in
the image's site-library, not in a mounted volume.

`REMOTES_MODE=strict` restores rwasm's behaviour; pass it with
`docker compose run --rm -e REMOTES_MODE=strict build`. **Re-check with it when
bumping `WEBR_VERSION`** ([operations.md](operations.md#webr_version-is-not-a-preference));
if it passes, the upstream issue is fixed and this workaround can be removed.

### Versions are pinned, and `WEBR_VERSION` is not a preference

A webR release fixes the ABI of every `.wasm` it produces. A browser running
webR X is not guaranteed to load packages built by webR Y. `WEBR_VERSION` is a
compatibility contract with whatever is deployed, and changing it means
rebuilding. See [operations.md](operations.md).

## The index files

`make_index.sh` writes two files at the top of each release tree:

- `pathlist`: every file in the tree, one per line, prefixed with the release
  (`3.23/bin/emscripten/contrib/4.6/...`) and sorted with `LC_ALL=C` so that
  rebuilds diff cleanly. It lists itself but not `index.html`. The hosting
  init container reads it (see [Hosting](#hosting)), so changing its shape is a
  decision rather than a cleanup.
- `index.html`: one link per `pathlist` entry, HTML-escaped.

`BUILDINFO` records the release, the source URL, the rwasm version, the build
image's R version, the package count, the build time and whether the build was
a subset.

## Hosting

Published releases are served from Kubernetes by the templates in
[`deploy/`](../deploy/):

| Host | Serves | Namespace |
|---|---|---|
| `https://webr.bioconductor.org/<release>/` | The published release trees | `webr` |
| `https://run.webr.bioconductor.org/` | A webR console page | `webr-repl` |

```
<RCLONE_REMOTE>/<release>/        object storage, the authoritative copy
      │
      │  init container: rclone, on every pod start
      ▼
webr-pvc  /mnt/webr-js2/<release>/
      │
      │  httpuv::runStaticServer(), port 8080
      ▼
webr-service :80  →  Traefik Ingress (TLS, CORS)  →  https://webr.bioconductor.org/<release>/
```

### webr.bioconductor.org

`webr-deployment` runs one replica with the `Recreate` strategy:

- **`init-rclone`** (`rclone/rclone:latest`) copies each release named in its
  script from `js2:/webr/<release>` onto the volume. For each release it
  copies the served directory aside, runs `rclone sync` into the copy, runs a
  second copy pass driven by the release's `pathlist`, then swaps the copy into
  place. It does not check whether the copies succeeded, and the second pass
  fetches nothing for 3.19 to 3.23
  ([Known limitations](deployment.md#known-limitations)). The script names the
  releases (3.18 to 3.23), the `js2` remote
  and the object store's public URL, from which it downloads `pathlist`.
- **`webr-container`** (`rocker/r-ver:latest`) installs httpuv from Posit
  Package Manager (`p3m.dev`, the repository `rocker/r-ver` configures), then
  serves `/mnt/webr-js2` with `httpuv::runStaticServer()` on port 8080 and an
  `Access-Control-Allow-Origin: *` header. Its probes check the TCP socket,
  because `/` has no index and answers 404.

The `webr` Ingress terminates TLS with a certificate from cert-manager and sets
`Access-Control-Allow-Origin: *` and `Access-Control-Allow-Methods: HEAD, GET,
OPTIONS` through the `webr-cors` Traefik middleware. A second Ingress on the
`web` entrypoint redirects HTTP to HTTPS.

A release's URL mirrors its object-storage path:
`js2:/webr/3.23/bin/emscripten/contrib/4.6/PACKAGES` is served as
`https://webr.bioconductor.org/3.23/bin/emscripten/contrib/4.6/PACKAGES`.

| Release | R version of the binaries |
|---|---|
| 3.18 | 4.3 |
| 3.19, 3.20 | 4.4 |
| 3.21, 3.22 | 4.5 |
| 3.23 | 4.6 |

### run.webr.bioconductor.org

`webr-repl` runs two `nginx:1.29-alpine` replicas serving the files in
[`deploy/repl-files/`](../deploy/repl-files/) from the `webr-repl-files`
ConfigMap. `index.html` is an R console page that loads webR from
`https://webr.r-wasm.org/latest/`; it does not install packages from
webr.bioconductor.org. `repl.mjs` is served alongside it but not loaded by the
page. nginx sends a `Content-Security-Policy` that limits sources to the page's
own origin and `webr.r-wasm.org`, and answers unknown paths with `index.html`.
The policy allows no inline script, so browsers block the page's script and the
console does not start; see [deployment.md](deployment.md#known-limitations).

### State

| What | Where | If it is lost |
|---|---|---|
| Release trees | Object storage, `js2:/webr/<release>` | Rebuild and republish each release |
| Served copy | `webr-pvc` | The init container copies it back, which takes hours |
| Object-storage credentials | Secret `rclone-conf` in `webr` | Recreate from the object store's credentials |
| TLS certificates | Secrets managed by cert-manager | cert-manager reissues them |
| REPL page | ConfigMaps generated from `deploy/repl-files/` | Reapply the templates |

### External dependencies

- Object storage holding the release trees, read with the `rclone-conf`
  credentials and, for `pathlist`, over public HTTPS.
- Posit Package Manager (`p3m.dev`), from which `webr-container` installs
  httpuv on every start.
- Docker Hub, for the `rclone/rclone`, `rocker/r-ver` and `nginx` images.
- Traefik as the ingress controller, and cert-manager with a ClusterIssuer that
  can validate the hostnames. Bioconductor's issuer answers DNS-01 challenges,
  which needs API access to the zone's authoritative DNS provider.
- `webr.r-wasm.org`, which serves webR to the REPL page and to
  [`demo/`](../demo/).

Known limitations of the hosting setup are listed in
[deployment.md](deployment.md#known-limitations).

## What is not here

- **No incremental rebuild across releases.** Each Bioconductor version is a
  separate tree. Packages unchanged between releases are compiled again. Sharing
  them would mean a content-addressed store and a way to prove two releases
  reference identical sources.
- **No per-package failure reporting.** rwasm builds what it can; a package that
  fails to compile is absent from the result. `verify` catches a tree that is
  wholesale too small, but nothing says *which* packages are missing and why.
  See [operations.md](operations.md#known-gaps).
- **No signing or checksums beyond what rclone verifies in transit.** See
  [security.md](security.md).
