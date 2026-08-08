# Architecture

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
  rebuilds diff cleanly. It lists itself but not `index.html`. Consumers may
  depend on that shape, so changing it is a decision rather than a cleanup.
- `index.html`: one link per `pathlist` entry, HTML-escaped.

`BUILDINFO` records the release, the source URL, the rwasm version, the build
image's R version, the package count, the build time and whether the build was
a subset.

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
