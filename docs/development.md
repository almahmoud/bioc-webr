# Development

Everything you need to work on this repository. If you have never seen it
before, start here and read [architecture.md](architecture.md) second.

## Setup

```bash
git clone https://github.com/almahmoud/bioc-webr
cd bioc-webr
cp .env.example .env
```

Edit `.env`. Two lines matter to start with:

```ini
BIOC_VERSION=3.23
HOST_UID=1000        # set to `id -u`
HOST_GID=1000        # set to `id -g`
```

`HOST_UID`/`HOST_GID` only affect ownership of the build logs written to
`./out`. Getting them wrong leaves root-owned log files; it does not break the
build.

That is the whole setup. There is no R to install, no Emscripten toolchain to
provision — the webR image carries both.

Check it:

```bash
docker compose config --quiet && echo ok
```

## The fast loop

**A full Bioconductor release is thousands of packages and takes hours.** You
cannot iterate against that. Use a subset:

```ini
# in .env
BIOC_PACKAGES=BiocGenerics
```

```bash
docker compose run --rm build
```

Minutes instead of hours. Only the named packages and their *hard* dependencies
are built. The output is marked with an `INCOMPLETE` file and
`docker compose run --rm verify` will refuse it, so a development artifact
cannot be published by accident.

Widen it as needed:

```ini
BIOC_PACKAGES=BiocGenerics S4Vectors IRanges
```

Names are plain Bioconductor package names. The script turns each into a
`bioc::` pkgdepends reference; anything already containing `::` or `/` is passed
through untouched, so `r-wasm/gt@webr` or `cran/s2@1.1.7` work if you need to
test a specific source.

### Starting clean

The built repository lives in a named volume that persists between runs, and
rwasm skips packages already in the `PACKAGES` index it finds there. That is what you want
for a real build and *not* what you want when testing a change to the build
logic:

```bash
docker volume rm bioc-webr_repo
```

The caches are separate and rarely need clearing:

```bash
docker volume rm bioc-webr_pkgcache bioc-webr_rlib
```

`docker compose down --volumes` removes all three.

### Looking at the result

```bash
# Serve it over HTTP, which is what webR needs
docker compose --profile serve up serve
# -> http://localhost:8080/

# Or copy it onto the host for inspection with your own tools
docker compose --profile export run --rm export
ls out/3.23/_site
```

Poking around inside the volume without either:

```bash
docker compose run --rm --entrypoint bash verify -c 'find /repo -type f | head -50'
```

## Layout

```
compose.yaml              the build stack. Five services, three profiles
scripts/
  entrypoint.sh           container-side driver: build -> index -> chown
  build_repo.R            the R half. Talks to rwasm
  make_index.sh           generates pathlist and index.html
  verify_site.sh          decides whether a tree is publishable
  publish.sh              host-side: verify, then rclone sync
  serve-nginx.conf        local preview server
.github/workflows/
  build.yml               reusable workflow. Calls the same compose services
  lint.yml                static checks on pull requests
demo/                     browser demo page
docs/                     you are here
```

**`scripts/` holds all the logic and `compose.yaml` only wires it up.** Nothing important lives in a compose
`command:` string, because those cannot be linted, tested, or read comfortably.

## Making a change

### Changing what gets built

`scripts/build_repo.R`. The two paths — subset and full release — are the two
branches at the bottom. Both funnel into rwasm.

Test with a subset build. If the change affects the full-release path
specifically, you cannot test it cheaply; say so in the PR rather than
implying it was verified.

### Changing the index format

`scripts/make_index.sh`. Two things there are load-bearing and look like
mistakes:

- **`pathlist` contains itself but not `index.html`.** The file is created empty
  before the tree walk so that it appears in its own listing, and `index.html`
  is generated afterwards. Consumers may depend on it. Changing it is a
  decision, not a cleanup.
- **Every path is prefixed with the Bioconductor version**, not with the site
  root, because the listing is consumed relative to the bucket root and the
  published tree lives under `<RCLONE_REMOTE>/<version>/`.

`verify_site.sh` checks both. If you change the format, change the check.

### Changing the publishability rules

`scripts/verify_site.sh`. It runs in a container against the built tree, which
is both where the files are and where GNU `find`/`grep`/`stat` are — a
maintainer on macOS would otherwise be running BSD tools against a tree built by
the GNU ones.

Test it against a subset build, which *should* fail:

```bash
docker compose run --rm verify; echo "exit=$?"
```

Expect a non-zero exit and `INCOMPLETE marker present`. A subset build that
passes verification is a bug in the check.

### Changing the workflow

`.github/workflows/build.yml` contains no build logic. It writes a
`.env`, runs `docker compose run --rm build`, and runs the same
`verify`/`publish` scripts you run locally. If you find yourself adding a build
step to the workflow that does not exist in `compose.yaml`, that is the signal
that it belongs in `scripts/`.

## Things that will bite you

### `fs::dir_create` fails on a macOS bind mount

This is why the repository is built in a named volume rather than in `./out`.

rwasm creates directories with `fs::dir_create()`, which creates the directory
and then chmods it. On a Docker Desktop bind mount from macOS that chmod fails —
the directory is created mode `0545` and the fix-up returns `EACCES`:

```
Error: [EACCES] Failed to set permissions for directory '/site/src': permission denied
```

Base R's `dir.create()` on the same path works, and on Linux, where bind mounts
are a real filesystem, both work.

If you move any part of the build back onto a bind mount, this returns.

### Three of rwasm's bundled remotes do not resolve

rwasm ships a list of GitHub references to packages patched for WebAssembly
(`inst/webr-remotes`, 17 entries). `prefer_remotes()` resolves the whole list in
one call, so **one bad reference aborts the entire build** — subset or full —
before a single package is compiled.

With the versions in webR v0.6.0 (rwasm 0.3.0.9000, pkgdepends 0.9.1), three
fail with `nrow(out) must equal 1`:

```
cran/mmrm@0.2.2      r-wasm/TMB@webr      r-wasm/rigraph@webr
```

The repositories, refs and DESCRIPTION files all exist and are reachable, so
this is an upstream resolution incompatibility rather than a dead reference.
(`rigraph`'s DESCRIPTION declares `Package: igraph` — repository name and
package name differ.)

`build_repo.R` works around it by resolving each reference individually and
using the ones that work. `REMOTES_MODE` controls this:

| Value | Behaviour |
|---|---|
| `filter` (default) | Resolve individually, use what works, report what was dropped |
| `strict` | rwasm's own behaviour. Fails if any reference is bad |
| `none` | Skip the bundled list entirely — upstream sources only |

Set it for one run with `docker compose run --rm -e REMOTES_MODE=strict build`.
Compose does not pass it from `.env` or the host environment into the
container.

**A dropped reference is not free.** That package, if the build needs it, comes
from upstream sources instead of its webR-patched fork and may fail to compile.
`igraph` is a dependency of several Bioconductor packages. This is why the
message is loud. Re-check with `REMOTES_MODE=strict` when bumping
`WEBR_VERSION`; if it passes, the upstream issue is fixed and the workaround
can go.

### GitHub API rate limits

Resolving those references costs unauthenticated GitHub API calls, and the
anonymous limit is 60/hour. Repeated builds will exhaust it, and the failure
looks like an unrelated resolution error.

Pass a token. Export it from your credential store rather than typing it on the
command line, then pass it into the container with `-e`:

```bash
export GITHUB_PAT="$(<command printing the token from your credential store>)"
docker compose run --rm -e GITHUB_PAT build
```

It needs no scopes — public read is enough. Code that runs during the build,
including third-party `configure` scripts, can read it.

### Memory

Emscripten link steps are memory-hungry and the failure mode is an opaque OOM
kill, often reported as a compilation error in whatever package was unlucky.
On Docker Desktop, check the VM's memory allocation in settings. rwasm compiles
one package at a time; `BUILD_JOBS` does not change that.

### Disk

A full release is tens of gigabytes across source tarballs and wasm binaries,
plus the `pkgcache` volume holding every downloaded source. `docker system df`
tells you where it went.

## Before opening a pull request

```bash
# Shell scripts parse
for f in scripts/*.sh; do bash -n "$f" || echo "FAILED: $f"; done

# R parses
docker run --rm -v "$PWD:/w:ro" -w /w r-base:4.4.2 \
  Rscript -e 'invisible(parse("scripts/build_repo.R")); cat("ok\n")'

# Compose is valid
docker compose config --quiet

# A subset build still works end to end
docker volume rm bioc-webr_repo 2>/dev/null || true
docker compose run --rm build
docker compose run --rm verify   # must FAIL - subset builds are not publishable
```

See [CONTRIBUTING.md](../CONTRIBUTING.md) for what to put in the pull request
itself — in particular, being explicit about which paths you exercised.
