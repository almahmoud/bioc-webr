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

## Hosting

### `https://webr.bioconductor.org/` answers 404

Expected. The server has no index above the release directories. Check a
release path instead:

```bash
curl -sI https://webr.bioconductor.org/3.23/bin/emscripten/contrib/4.6/PACKAGES
```

### Every path fails after a restart

The init container is still copying releases. The server starts only when it
finishes, which takes hours; until then the ingress has no ready endpoint.

```bash
kubectl -n webr get pods
kubectl -n webr logs deploy/webr-deployment -c init-rclone --tail=50
```

### A published release answers 404

The release is in object storage but not on the served volume. Either the init
script in `deploy/20-webr.yaml` does not name it, or the pod has not restarted
since it was published. See
[operations.md](operations.md#serving-a-new-release).

### A release is stale or missing files after a restart

The init script does not stop on errors: a failed `rclone` call is logged, the
script moves on, and the copy is swapped into place whatever its state. Its
second pass fetches nothing for 3.19 to 3.23
([Known limitations](deployment.md#known-limitations)), so a file that
`rclone sync` missed stays missing. The completeness check in
[operations.md](operations.md#health-checks) lists the missing binaries;
restarting the Deployment copies every release again.

The init container's log has errors on every start, even with working
credentials: the second pass requests every `pathlist` entry of 3.21 onwards
at a path that does not exist, and `wget` finds no `pathlist` for 3.19 and
3.20. Look at the first errors in the log:

```bash
kubectl -n webr logs deploy/webr-deployment -c init-rclone | grep -i -E 'error|failed' | head
```

Authentication errors there mean the credentials are wrong. The secret must
have the key `rclone.conf`, defining the remote the script names (`js2`). List
the keys without printing the values:

```bash
kubectl -n webr get secret rclone-conf \
  -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
```

A pod that stays in `Init:0/1` with `secret "rclone-conf" not found` in its
events (`kubectl -n webr describe pod -l app=webr`) means the secret was never
created; see [deployment.md](deployment.md#deploying-from-scratch).

### `webr-container` restarts in a loop

It installs httpuv before serving, from Posit Package Manager (`p3m.dev`), the
repository `rocker/r-ver` configures. An outage there, or a network policy
blocking it, stops it there:

```bash
kubectl -n webr logs deploy/webr-deployment -c webr-container --previous
```

### webR in a browser cannot install from webr.bioconductor.org

- **R version**: webR looks in `bin/emscripten/contrib/<its R version>/`. A
  release built for another R version has no binaries there; see the table in
  [architecture.md](architecture.md#webrbioconductororg).
- **Repository URL**: pass the release root, `https://webr.bioconductor.org/3.23`,
  not the `bin/emscripten/contrib/` directory.
- **CORS**: the response must carry `access-control-allow-origin: *`:

  ```bash
  curl -sI https://webr.bioconductor.org/3.23/bin/emscripten/contrib/4.6/PACKAGES \
    | grep -i access-control
  ```

### A certificate is not renewed

```bash
kubectl -n webr describe certificate webr-bioconductor-org-tls
kubectl -n webr-repl describe certificate run-webr-bioconductor-org-tls
kubectl get certificaterequests,orders,challenges -A
```

The ClusterIssuer has to complete its challenge for each hostname. A DNS-01
solver needs working API credentials for the provider that is authoritative for
the zone; compare its configuration with:

```bash
dig +short NS bioconductor.org
```

An HTTP-01 solver needs the hostname to resolve to the ingress.

### run.webr.bioconductor.org stays on "Loading webR, please wait..."

The page's `Content-Security-Policy` allows no inline script, so browsers block
the page's script and webR never loads; the browser console reports the
blocked script. [deployment.md](deployment.md#known-limitations) describes the
fix.

Once the script runs, the page loads webR from
`https://webr.r-wasm.org/latest/`. Check that it is reachable:

```bash
curl -sI https://webr.r-wasm.org/latest/webr.mjs
```

## Cleaning up entirely

```bash
docker compose down --volumes    # removes repo, pkgcache and rlib
rm -rf out/
```

The built repository is gone and takes hours to reproduce. The caches are free
to discard.
