# Operations

Running real builds and publishing them.

## Version pinning

| Pin | Where | Current | Why it matters |
|---|---|---|---|
| `WEBR_VERSION` | `.env` | `v0.6.0` | **The compatibility contract.** See below |
| `BIOC_VERSION` | `.env` | per build | The only real input |
| `RCLONE_VERSION` | `.env` | `1.71` | Publishing only |
| `NGINX_VERSION` | `.env` | `1.29-alpine` | Local preview only |
| `debian:12-slim` | `compose.yaml` | — | `verify` and `export` |

### `WEBR_VERSION` is not a preference

A webR release fixes the ABI of every `.wasm` it produces. A browser running
webR X is not guaranteed to load packages built by webR Y. This pin is a
contract with whatever webR is deployed to users.

Consequences:

- **Bumping it for a published release means rebuilding that release.**
  Releases for other R versions are unaffected: their binaries sit under a
  different `bin/emscripten/contrib/<r-version>/` and are loaded by webR builds
  of that R version.
- **Check what is deployed first.** If a site embeds webR from a CDN at a
  floating version, that version — not this file — decides what the repository
  has to match.
- The R version follows from the image (`v0.6.0` → R 4.6.0) and determines the
  `bin/emscripten/contrib/<r-version>/` path in the output. Changing webR can
  therefore change the repository's shape, not only its contents.

Bump procedure:

```bash
# 1. Check whether the upstream rwasm remotes issue is fixed in the new image
BIOC_PACKAGES=BiocGenerics WEBR_VERSION=<new> \
  docker compose run --rm -e REMOTES_MODE=strict build

# 2. Subset build against the new image
BIOC_PACKAGES=BiocGenerics WEBR_VERSION=<new> docker compose run --rm build

# 3. Load a package from it in a real webR session before committing the bump
docker compose --profile serve up serve
```

`REMOTES_MODE` reaches the container only through `-e`; step 1's log shows
`REMOTES_MODE=strict - rwasm resolves its bundled list as a batch`. If step 1
succeeds, remove the workaround described in
[architecture.md](architecture.md#rwasms-bundled-remotes-are-filtered).

## A full release build

```bash
# .env
BIOC_VERSION=3.23
BIOC_PACKAGES=            # empty - this is what makes it a full build
```

```bash
docker compose run --rm build
```

### Where to run it

Not on a laptop, and not on a standard GitHub-hosted runner.

| | Needed |
|---|---|
| Disk | tens of GB for the tree, plus the `pkgcache` volume holding every source tarball |
| Memory | 8 GB or more. Emscripten link steps are the hungry part |
| Time | hours |

A hosted `ubuntu-latest` runner has roughly 14 GB free and a six-hour job
limit. The reusable workflow's `runs_on` input exists for this — point it at a
self-hosted runner with real disk. See [deployment.md](deployment.md).

### Re-running a build

The repository lives in a named volume. On a re-run, rwasm skips every package
already in the binary `PACKAGES` index at the same version and builds the rest,
reusing source tarballs it has already downloaded:

```bash
docker compose run --rm build
```

rwasm rewrites the index at the end of a run only if that run downloaded at
least one source tarball. A re-run that only retries packages whose sources are
already in `src/contrib/`, such as packages that failed to compile, builds them
but leaves them out of the index, and `verify` refuses the tree; see
[troubleshooting.md](troubleshooting.md#packages-lists-n-packages-but-m-tgz-files-are-present).

The volume is not cleaned automatically. To force a clean build:

```bash
docker volume rm bioc-webr_repo
```

Start from an empty volume when rebuilding a release the volume already holds,
for example to pick up package updates. When a package's version changes,
rwasm deletes the old source tarball but keeps the old binary, so the tree ends
up with more binaries than its index lists.

### Packages that fail to compile

Some will. rwasm builds what it can and a package that fails is absent
from the result — there is no per-package failure report
(see [Known gaps](#known-gaps)).

When a package blocks progress, exclude it:

```ini
BIOC_SKIP_REGEX=^(SomeBrokenPkg|AnotherOne)$
```

**Record why, here, with a date.** An unexplained skip regex is indistinguishable
from an accident six months later, and the packages that depend on the excluded
one will also be missing without any obvious cause.

<!-- Skipped packages, most recent first, with the release and the reason. -->

## Publishing

```bash
scripts/publish.sh --check-only   # validate, change nothing
scripts/publish.sh --dry-run      # show what would change on the remote
scripts/publish.sh                # publish
```

### What the gate is protecting

`rclone sync` **deletes remote files that are absent locally.** Publishing a
half-built tree does not merely fail to add packages — it destroys the working
repository already published under that version, and there is no undo.

`publish.sh` runs `verify` first and refuses on failure. The checks:

- no `INCOMPLETE` marker (subset builds cannot be published)
- `BUILDINFO` exists and its version matches `BIOC_VERSION`
- a `bin/emscripten/contrib/*/PACKAGES` index exists and is non-empty
- at least `MIN_PACKAGES` binaries are present
- the `PACKAGES` index count matches the `.tgz` files on disk
- `pathlist` and `index.html` exist, and every path carries the version prefix

`MIN_PACKAGES` catches a build that stopped early. **Set it from the previous
release's count**, not from a round number — a build that stops a third of the
way through still produces hundreds of packages.

`--force` exists and requires typing the version number. It is for the case
where you have decided the checks are wrong.

### Configuration

```ini
RCLONE_REMOTE=js2:/webr
RCLONE_CONFIG_DIR=/home/you/.config/rclone   # absolute; Compose will not expand ~
```

The published layout puts each release under its own prefix, so they coexist:

```
<RCLONE_REMOTE>/3.23/...
<RCLONE_REMOTE>/3.24/...
```

`publish.sh` only ever writes under `<RCLONE_REMOTE>/<BIOC_VERSION>`, so a sync
for one release cannot touch another.

## Release cadence

Bioconductor releases twice a year, in spring and autumn.

### At each release

- [ ] Confirm the new version exists:
      `curl -sI https://bioconductor.org/packages/<new>/bioc/src/contrib/PACKAGES`
- [ ] Set `BIOC_VERSION` and run a subset build to confirm the release is
      reachable and resolvable before committing hours to it.
- [ ] Run the full build.
- [ ] `scripts/publish.sh --check-only`, and update `MIN_PACKAGES` to reflect the
      new count once satisfied.
- [ ] `scripts/publish.sh --dry-run`, then publish.
- [ ] Load a package in a real webR session against the published URL.
- [ ] Decide what happens to the oldest release still published.

### Quarterly

- [ ] Check for a new webR release. Read its notes for ABI or layout changes
      before bumping.
- [ ] Run step 1 of the [bump procedure](#webr_version-is-not-a-preference)
      with the current `WEBR_VERSION` to see whether the upstream rwasm
      resolution failure is fixed. If it is, delete the workaround.
- [ ] `docker system df` on the build host. The `pkgcache` volume grows without
      bound.

## Recovery

### A build died partway

Run it again; see [Re-running a build](#re-running-a-build). If it dies
repeatedly at the same package, that package is the problem — exclude it via `BIOC_SKIP_REGEX` and record why.

### A publish was interrupted

Run `scripts/publish.sh` again. `rclone sync` is idempotent and `--checksum`
means it re-uploads only what differs.

The dangerous state is a publish interrupted partway through its *deletions*,
leaving the remote with a mix of two builds. Re-running from a good local tree
converges it.

### The published repository is broken and the local tree is gone

There is no backup, by design — the repository is reproducible from a
Bioconductor release number. Rebuild and republish. It costs hours, not data.

The exception is a Bioconductor release that has since been withdrawn or
altered upstream, in which case the published tree was the only copy. This is
why `BUILDINFO` records the exact source URL.

## Known gaps

Ordered by how much they would help.

**No per-package failure reporting.** A package that fails to compile is absent
from the result and nothing says which, or why. `verify` catches a tree that is
wholesale too small, but not "342 packages failed for the same missing system
library". Capturing rwasm's per-package outcome in a report alongside
`BUILDINFO` would close this gap.

**No comparison against the previous release.** A build producing 1,900 packages
when the last produced 2,200 passes every check. Diffing the `PACKAGES` index
against the previous release's would catch a regression that
`MIN_PACKAGES` cannot.

**No integrity verification after publish.** `rclone --checksum` verifies
transfer, but nothing fetches the published `PACKAGES` afterwards and confirms
every listed package is retrievable.

**Each release is built from scratch.** Packages unchanged between releases are
recompiled. Sharing them needs a content-addressed store and a way to prove two
releases reference identical sources.
