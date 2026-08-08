# Troubleshooting

Symptom first.

## Build

### `[EACCES] Failed to set permissions for directory '/site/src'`

You are building onto a bind mount from macOS.

rwasm creates directories with `fs::dir_create()`, which creates the directory
and then chmods it. On a Docker Desktop bind mount that chmod fails — the
directory is created mode `0545` and the fix-up returns `EACCES`.

The stack builds into a named volume specifically to avoid this. If you see it,
something has been changed to write into `./out` directly. Put it back.

Confirm the diagnosis:

```bash
docker run --rm -v "$PWD/out:/site" -v bioc-webr_rlib:/vol \
  --entrypoint Rscript ghcr.io/r-wasm/webr:v0.6.0 -e \
  'for (d in c("/site/x", "/vol/x")) cat(d, tryCatch({fs::dir_create(d); unlink(d, recursive = TRUE); "ok"}, error = conditionMessage), "\n")'
```

Fails on the bind mount, succeeds on the volume.

### `nrow(out) must equal 1` before any package compiles

rwasm's bundled webR remotes. `prefer_remotes()` resolves all 17 GitHub
references in one call, and with rwasm 0.3.0.9000 / pkgdepends 0.9.1 three of
them fail:

```
cran/mmrm@0.2.2      r-wasm/TMB@webr      r-wasm/rigraph@webr
```

`build_repo.R` filters them by default (`REMOTES_MODE=filter`), so this error
means either the mode was changed to `strict`, or a *different* reference has
started failing.

Find out which:

```bash
docker compose run --rm --entrypoint Rscript build -e '
rem <- unique(readLines(system.file("webr-remotes", package="rwasm")))
for (r in rem) {
  res <- tryCatch({
    p <- pkgdepends::new_pkg_download_proposal(r, config=rwasm:::ppm_config)
    p$resolve(); "ok"
  }, error=function(e) conditionMessage(e))
  cat(sprintf("%-40s %s\n", r, res))
}'
```

If a new reference has started failing, the filter handles it — but check
whether the package matters to Bioconductor before accepting the loss.

### `the condition has length > 1` in `prefer_remotes`

Something is passing a character vector as rwasm's `remotes=` argument.
`prefer_remotes()` opens with `if (is.na(remotes))`, which on a vector of
length > 1 is an error rather than a test, so despite the documentation that
parameter only accepts `NA` or `NULL`.

`build_repo.R` works around it by writing the filtered list back over rwasm's
own bundled file and passing `NA`. If you changed that, this is why.

### `! Using bundled GitHub PAT` then a resolution failure

GitHub API rate limiting. The anonymous limit is 60 requests an hour and
checking the bundled remotes spends 17 of them per build.

```bash
export GITHUB_PAT="$(<command printing the token from your credential store>)"
docker compose run --rm -e GITHUB_PAT build
```

`-e GITHUB_PAT` passes the exported variable into the container; Compose does
not pass it otherwise. No scopes needed — public read is enough, and code that
runs during the build can read it. Check where you stand:

```bash
curl -s https://api.github.com/rate_limit | head -20
```

### The build is killed with no error, or a package fails to link for no reason

Almost always memory. Emscripten link steps are the hungry part and an OOM kill
surfaces as whatever the unlucky package was doing at the time.

- On Docker Desktop, raise the VM's memory allocation in settings — the default
  is often 2–8 GB regardless of how much the host has.

```bash
docker stats --no-stream
```

### `no packages were built - refusing to report success`

The build ran and produced nothing. Look above it in the log for the real cause:
usually a resolution failure, or a `BIOC_VERSION` that does not exist.

Check the release is real:

```bash
curl -sI https://bioconductor.org/packages/3.23/bioc/src/contrib/PACKAGES
```

### The build restarts from scratch every time

The repository volume was removed, the version changed, or no earlier run
wrote the index. rwasm skips packages listed in the binary `PACKAGES` index,
which it rewrites at the end of a run that downloaded at least one source
tarball.

```bash
docker volume ls | grep bioc-webr
```

### Out of disk

```bash
docker system df
```

The `pkgcache` volume holds every downloaded source tarball and grows without
bound.

```bash
docker volume rm bioc-webr_pkgcache    # safe; it is only a cache
```

Do not remove `bioc-webr_repo` unless you mean to discard the build.

## Verify

### `INCOMPLETE marker present`

Working as intended. `BIOC_PACKAGES` was set, so this is a development subset
build. Clear it and rebuild for a real one.

### `N binary packages, expected at least 500`

Either the build stopped early, or `MIN_PACKAGES` is wrong. Check `BUILDINFO`
for what the build thought it produced, and the build log for where it stopped.

`MIN_PACKAGES` should come from the previous release's count. A build that dies
a third of the way through still produces hundreds of packages.

### `PACKAGES lists N packages but M .tgz files are present`

The index and the binaries on disk disagree, so the tree is not what a
complete build produces.

rwasm leaves a tree like this in three cases:

- **A re-run that downloaded nothing.** rwasm rewrites the index only when a
  run downloaded at least one source tarball, so packages rebuilt from sources
  already in `src/contrib/`, such as earlier failures, are not indexed.
- **A package version changed.** rwasm deletes the old source tarball but
  keeps the old binary, `<pkg>_<old-version>.tgz`, next to the new one.
- **Two R versions.** The volume holds builds of the release from webR images
  with different R versions, so there are two `bin/emscripten/contrib/`
  directories and `verify` counts the binaries in both.

Starting from an empty volume fixes all three:

```bash
docker volume rm bioc-webr_repo
docker compose run --rm build
```

To keep the built packages in the first two cases, rewrite the index and the
listing. In the second case, first list the packages with more than one binary
and delete the older binary of each:

```bash
docker compose run --rm --entrypoint bash verify -c '
  cd "$SITE_DIR"/bin/emscripten/contrib/*/ &&
  for p in $(ls *.tgz | sed "s/_.*//" | sort | uniq -d); do ls "$p"_*.tgz; done'
docker compose run --rm --entrypoint bash build -c \
  'rm -v "$SITE_DIR"/bin/emscripten/contrib/*/<pkg>_<old-version>.tgz'
```

```bash
docker compose run --rm --entrypoint Rscript build \
  -e 'rwasm::write_packages(Sys.getenv("SITE_DIR"))'
docker compose run --rm --entrypoint bash build -c 'bash scripts/make_index.sh "$SITE_DIR"'
```

### `pathlist entries are not prefixed <version>/`

`make_index.sh` ran with a different `BIOC_VERSION` than `verify` is checking,
or the site directory moved. Rebuild the index by re-running the build.

## Publish

### `RCLONE_CONFIG_DIR must be an absolute path`

Compose does not expand `~`. Write the path out in full.

### `Refusing to publish`

Read the verify output above it — this is the gate doing its job. `rclone sync`
deletes remote files absent locally, so publishing a bad tree destroys the
published repository rather than merely failing to improve it.

`--force` exists and requires typing the version number.

### rclone cannot find the remote

```bash
docker compose --profile publish run --rm publish listremotes
```

If your remote is not listed, `RCLONE_CONFIG_DIR` is pointing at the wrong
directory. It must contain `rclone.conf` — the directory, not the file.

### Publishing deleted files I wanted to keep

`sync` mirrors. Anything on the remote under `<RCLONE_REMOTE>/<version>/` that is not
in the local tree is removed.

If the local tree was good and complete, this is correct behaviour and the
deleted files were stale. If it was not, rebuild and republish — the repository
is reproducible from a release number, which is why there is no backup.

Use `--dry-run` first. It is not a formality.

## Serve

### `docker compose --profile serve up serve` starts but 404s everything

Nothing has been built for that `BIOC_VERSION`, or the version in `.env` does
not match what is in the volume:

```bash
docker compose run --rm --entrypoint bash verify -c 'ls /repo'
```

### webR cannot install from the local server

- **Port**: the URL is `http://localhost:${SERVE_PORT}/`, default 8080.
- **CORS**: the config sets `Access-Control-Allow-Origin: *`. Confirm with
  `curl -I`.
- **Path**: webR wants the repository root — the directory *containing*
  `bin/emscripten/`, not the `bin/emscripten/contrib/<ver>/` directory itself.
- **Mixed content**: a page served over HTTPS cannot fetch from
  `http://localhost`. Serve the page over HTTP too while testing.

## Cleaning up entirely

```bash
docker compose down --volumes    # removes repo, pkgcache and rlib
rm -rf out/
```

The built repository is gone and takes hours to reproduce. The caches are free
to discard.
