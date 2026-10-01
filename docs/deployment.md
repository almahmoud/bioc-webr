# Deployment

Running builds somewhere other than a laptop, and deploying the hosting that
serves published releases ([Hosting](#hosting)).

## The reusable workflow

[`.github/workflows/build.yml`](../.github/workflows/build.yml) is callable
from another repository:

```yaml
jobs:
  webr:
    uses: almahmoud/bioc-webr/.github/workflows/build.yml@main
    with:
      bioc_version: '3.23'
      runs_on: 'self-hosted-large'
      publish: true
      rclone_remote: 'js2:/webr'
    secrets:
      rclone_config: ${{ secrets.RCLONE_CONFIG }}
```

It contains no build logic. It writes a `.env`, runs
`docker compose run --rm build`, and its later steps call
`scripts/publish.sh`, the script a developer runs locally to verify and
publish. There is no CI-only build path.

**The workflow stops after the build.** Its Summarise step reads
`out/<release>/_site`, which the build does not write: the tree stays in the
`repo` volume and only the logs go to `out/`. The step fails, so Validate and
Publish do not run; publish from a build host
([Building on a VM directly](#building-on-a-vm-directly)). The
`workflow_dispatch` form also has no `rclone_remote` input, so `publish: true`
from the Actions tab fails at the Publish step.

### Inputs

| Input | Default | Notes |
|---|---|---|
| `bioc_version` | *required* | e.g. `3.23` |
| `webr_version` | `v0.6.0` | Fixes the wasm ABI — see [operations.md](operations.md#webr_version-is-not-a-preference) |
| `packages` | `''` | Subset build. Output is marked `INCOMPLETE` and cannot be published |
| `build_jobs` | `2` | R's `Ncpus` for the build driver. rwasm compiles packages one at a time |
| `publish` | `false` | Requires `rclone_remote` and the `rclone_config` secret |
| `rclone_remote` | `''` | e.g. `js2:/webr` |
| `min_packages` | `500` | Refuse to publish below this. Set from the previous release's count |
| `runs_on` | `ubuntu-latest` | **A full release needs a bigger runner** |

### Outputs

| Output | |
|---|---|
| `packages_built` | Count of WebAssembly binaries produced |
| `published` | Whether publishing ran and succeeded |

## Runner requirements

**A hosted `ubuntu-latest` runner cannot build a full release.** Roughly 14 GB
free disk against tens of GB needed, and a six-hour job limit against a build
measured in hours.

The workflow reclaims what it can when running on a hosted runner — deleting the
preinstalled .NET, Android and Haskell toolchains buys back around 25 GB — which
is enough for a subset build or a small release, but not for a full release.

For full releases, use a self-hosted runner or a VM:

| | Minimum | Comfortable |
|---|---|---|
| Disk | 100 GB | 250 GB+ |
| Memory | 8 GB | 32 GB+ |
| Cores | 2 | 4+ |

rwasm compiles one package at a time, so extra cores do little for a build.
Running out of memory during an Emscripten link step is an opaque OOM kill,
reported as a compile error in whatever package was being linked.

## Building on a VM directly

No CI needed. The stack is the same:

```bash
ssh <build-host>
git clone https://github.com/almahmoud/bioc-webr
cd bioc-webr
cp .env.example .env
# set BIOC_VERSION and HOST_UID/HOST_GID; to publish, also RCLONE_REMOTE,
# RCLONE_CONFIG_DIR and MIN_PACKAGES; see docs/examples/production.env

docker compose run --rm build
docker compose run --rm verify
scripts/publish.sh
```

Run it under `tmux` or `screen`. A dropped SSH session kills the build, and the
next run rebuilds every package the killed run had built.

```bash
tmux new -s webr
docker compose run --rm build
# detach: Ctrl-b d      reattach: tmux attach -t webr
```

## Self-hosted runner

Register the runner on the repository that calls the workflow, or in an
organisation runner group that repository can use. A called workflow runs in
the caller's context and reaches only the caller's runners.

```bash
# On the build host, as a non-root user in the docker group.
# <version> is the latest release at https://github.com/actions/runner/releases,
# without the leading v; its release notes list the SHA-256 for linux-x64.
RUNNER_VERSION=<version>
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
echo "<sha256 from the release notes>  actions-runner-linux-x64.tar.gz" | sha256sum -c
tar xzf actions-runner-linux-x64.tar.gz
./config.sh --url https://github.com/<owner>/<calling-repository> \
            --token <from the repository's runner settings> \
            --labels self-hosted-large
sudo ./svc.sh install && sudo ./svc.sh start
```

Then pass `runs_on: 'self-hosted-large'` from the calling workflow.

Before registering one:

- **Do not register the runner on a public repository, including this one.**
  A pull request from a fork runs the workflows as that pull request changes
  them, so it can add a job with `runs-on: self-hosted-large` and run any code
  on the host. GitHub's approval settings for fork pull requests hold back
  only some contributors by default. Use a private calling repository, or an
  organisation runner group that public repositories cannot use. See
  [security.md](security.md#build-host).
- **The runner needs Docker and a user in the `docker` group**, which is
  effectively root on that host. Every job can read what the host holds,
  including an `rclone.conf` kept there for publishing from a shell, and can
  change the `bioc-webr_repo` volume that `scripts/publish.sh` syncs. Do not
  put the runner on a machine that holds anything else.

## Publishing from CI

Store the contents of `rclone.conf` as a repository secret (`RCLONE_CONFIG`).
The workflow writes it to `$RUNNER_TEMP` with mode 600, points
`RCLONE_CONFIG_DIR` at it, and removes it in an `always()` step.

**On a self-hosted runner, the file is on a persistent disk.** The runner
empties `$RUNNER_TEMP` at the start and end of each job, but a runner that
stops mid-job leaves the file in place until its next job starts. Check the
host after a runner crash.

See [security.md](security.md#publishing-credentials) for what that credential
grants and how to scope it.

## Scheduling

Builds are not scheduled. A build is hours of compute and a publish overwrites
a live repository, so a maintainer starts both.

If you do want a scheduled build — for instance to track Bioconductor devel —
build without publishing and let a human promote it:

```yaml
on:
  schedule:
    - cron: '0 2 * * 0'   # Sundays, 02:00 UTC
jobs:
  devel:
    uses: almahmoud/bioc-webr/.github/workflows/build.yml@main
    with:
      bioc_version: '3.24'
      publish: false        # never on a schedule
      runs_on: 'self-hosted-large'
```

The `concurrency` group in the workflow is keyed on `bioc_version`, so a
scheduled run cannot collide with a manual one for the same release. Two
concurrent builds of the same version on one host would race on the same
volume.

## Hosting

[`deploy/`](../deploy/) holds the Kubernetes templates that serve
`webr.bioconductor.org` and `run.webr.bioconductor.org`, as described in
[architecture.md](architecture.md#hosting). They are a kustomize directory:

```bash
kubectl kustomize deploy/
```

### Requirements

- Traefik as the ingress controller, with its `traefik.io/v1alpha1` CRDs.
- cert-manager, and a ClusterIssuer that can issue certificates for both
  hostnames.
- A storage class for a 250 Gi `ReadWriteOnce` volume.
- Object storage holding the published releases, and an `rclone.conf` that can
  read it.

### Site-specific values

| Value | Where | Bioconductor's value |
|---|---|---|
| Storage class and size | `deploy/10-webr-storage.yaml` | `nfs-client`, `250Gi` |
| ClusterIssuer | `deploy/30-webr-ingress.yaml`, `deploy/40-webr-repl.yaml` | `ssl-wildcard` |
| Hostnames | `deploy/30-webr-ingress.yaml`, `deploy/40-webr-repl.yaml` | `webr.bioconductor.org`, `run.webr.bioconductor.org` |
| rclone remote and bucket | init script in `deploy/20-webr.yaml` | `js2:/webr` |
| Public URL of the bucket | init script in `deploy/20-webr.yaml` | `https://js2.jetstream-cloud.org:8001/swift/v1/webr` |
| Releases served | init script in `deploy/20-webr.yaml` | 3.18 to 3.23 |

[`examples/site-overlay/`](examples/site-overlay/) is a kustomize overlay that
sets the storage, issuer and hostnames for another site.

### Deploying from scratch

1. Create the namespaces and the object-storage credentials. The secret holds
   the rclone configuration under the key `rclone.conf`, and that
   configuration defines the remote named in the init script (`js2`). It is
   created by hand and never committed.

   ```bash
   kubectl apply -f deploy/00-namespace.yaml
   kubectl -n webr create secret generic rclone-conf \
     --from-file=rclone.conf=<path-to-rclone.conf>
   ```

2. Review the rendered manifests, then apply them:

   ```bash
   kubectl kustomize deploy/ | less
   kubectl apply -k deploy/
   ```

3. Wait for the certificates and the rollouts. The init container copies every
   release before the server starts, so the first rollout takes hours;
   `progressDeadlineSeconds` is set to 24 hours for that reason.

   ```bash
   kubectl -n webr get certificate
   kubectl -n webr-repl get certificate
   kubectl -n webr logs deploy/webr-deployment -c init-rclone -f
   kubectl -n webr rollout status deploy/webr-deployment --timeout=24h
   kubectl -n webr-repl rollout status deploy/webr-repl
   ```

   An issuer that uses HTTP-01 challenges issues the certificates only after
   DNS points at the ingress (step 5).

4. Check both hosts through the ingress before DNS points at it. `--resolve`
   takes an IP address, not a hostname:

   ```bash
   INGRESS=<ingress-ip>
   curl -sI --resolve webr.bioconductor.org:443:$INGRESS \
     https://webr.bioconductor.org/3.23/bin/emscripten/contrib/4.6/PACKAGES
   curl -sI --resolve run.webr.bioconductor.org:443:$INGRESS \
     https://run.webr.bioconductor.org/
   ```

   Both answer `200`; the first also carries
   `access-control-allow-origin: *`. With an HTTP-01 issuer the certificates
   do not exist yet: add `-k` to both commands, or run this step after step 5.

5. Point the DNS records for both hostnames at the ingress, then run the
   [health checks](operations.md#health-checks).

### Known limitations

The templates match the running deployment, including these limitations:

- **Every pod start copies every release.** The init container re-syncs all
  six releases, about 140 GB, before the server starts. A restart or a
  rescheduled pod is an outage of several hours, and the volume needs room for
  a second copy of the release being refreshed. Running the sync as a CronJob
  and letting the Deployment serve the volume would make restarts immediate.
- **A release can be served with files missing.** The init script does not
  check `rclone`'s exit status, and swaps the copy into place whatever its
  state. Its second pass, which fetches the `pathlist` entries missing after
  `rclone sync`, has its `sed` pattern in single quotes, so `$BIOCVER` is not
  expanded and `firstround` keeps absolute paths. For releases whose
  `pathlist` entries carry the release prefix (3.21 onwards), every request
  then goes to `js2:/webr/<release>/<release>/...` and fails; 3.19 and 3.20
  have no `pathlist`. Only 3.18's second pass fetches files. Run the
  completeness check in [operations.md](operations.md#health-checks) after
  every restart.
- **The server installs httpuv at startup.** `webr-container` runs
  `install.packages("httpuv")` on `rocker/r-ver:latest` before it serves, so
  every start needs Posit Package Manager (`p3m.dev`), the repository
  `rocker/r-ver` configures. An image with httpuv installed, or any static
  file server, removes that dependency.
- **CORS covers the origin and methods headers only.** Responses carry one
  `Access-Control-Allow-Origin: *` and `Access-Control-Allow-Methods: HEAD,
  GET, OPTIONS`. There is no `Access-Control-Allow-Credentials`, and browsers
  reject a wildcard origin on credentialed requests, so cross-origin requests
  made with credentials fail.
- **Images use floating tags.** `rclone/rclone:latest` and
  `rocker/r-ver:latest` change on the next pull, and the REPL page loads webR
  `latest` from `webr.r-wasm.org`.
- **The REPL page does not start.** nginx sends
  `Content-Security-Policy: default-src 'self' https://webr.r-wasm.org; worker-src 'self' blob:;`.
  It allows no `'unsafe-inline'`, nonce or hash for scripts, so browsers block
  the page's inline module script and its `onclick` handler, and webR never
  loads. It also lacks `'wasm-unsafe-eval'`, without which browsers refuse to
  compile WebAssembly under a policy that restricts scripts. The fix moves the
  script into a same-origin file, replaces `onclick` with `addEventListener`
  and adds `'wasm-unsafe-eval'` to the policy; apply it to
  `deploy/repl-files/` and the running ConfigMaps together, and check the page
  in Chromium, Firefox and Safari.
- **`repl.mjs` names an unrelated package repository.**
  `deploy/repl-files/repl.mjs` is served at
  `https://run.webr.bioconductor.org/repl.mjs` but not loaded by the page. It
  sets webR's `repos` and `webr_pkg_repos` to `https://my-repo.com`, a domain
  outside Bioconductor's control, ahead of `repo.r-wasm.org`. Do not load or
  copy it; remove it from `deploy/repl-files/` and the running ConfigMap
  together.
