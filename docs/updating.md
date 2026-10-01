# Updating

What this service depends on, how often each part is updated, how to update it,
how to check the result and how to roll back.

## Cadence

| Component | Pinned in | Cadence |
|---|---|---|
| Bioconductor release builds | `BIOC_VERSION` | Twice a year, at each Bioconductor release |
| webR image: R, Emscripten, rwasm | `WEBR_VERSION` | When a Bioconductor release needs a new R version; otherwise reviewed quarterly |
| Build helper images | `.env.example`, `examples/production.env`, `compose.yaml`, `lint.yml` | Quarterly |
| GitHub Actions | `.github/workflows/*.yml` | Quarterly, and when GitHub deprecates an action runtime |
| Self-hosted runner | The build host | Updates itself; checked quarterly |
| Hosting images | `deploy/` | `latest` tags on every pod start; `nginx` quarterly |
| Served releases | `deploy/20-webr.yaml` | At each Bioconductor release |
| k3s, Traefik, cert-manager | The cluster | Each Kubernetes minor version, before the running one reaches end of support |

## Bioconductor releases

Bioconductor releases twice a year, in April or May and in October or November.
The spring release moves to the new R minor version; the autumn release keeps
it. The R version of each release is in Bioconductor's configuration:

```bash
curl -s https://bioconductor.org/config.yaml \
  | sed -n '/^r_ver_for_bioc_ver:/,/^release_dates:/p' | grep '"3\.2[0-9]"'
```

Procedure:

1. Compare that R version with the R version of the webR image in use:

   ```bash
   docker compose run --rm --entrypoint cat build /opt/webr/R/R-VERSION
   ```

   If they differ, update the webR image first ([webR image](#webr-image)).
   The spring release waits for a webR release with the new R version.
2. Build, verify and publish the release as described in
   [operations.md](operations.md#at-each-release). Check the tree before
   publishing:

   ```bash
   scripts/publish.sh --check-only
   ```

3. Serve it ([operations.md](operations.md#serving-a-new-release)) and run the
   [health checks](operations.md#health-checks).
4. Set `MIN_PACKAGES` for the next build from the published count.
   `<r-version>` is the release's R version as major.minor, e.g. `4.6`:

   ```bash
   curl -s https://webr.bioconductor.org/<release>/bin/emscripten/contrib/<r-version>/PACKAGES \
     | grep -c '^Package:'
   ```

Rollback: a new release has no earlier tree to return to. Stop serving it as
described in [Retiring a release](operations.md#retiring-a-release), or fix
the build and republish. Republishing an
existing release replaces it in object storage; unless the object store keeps
versions, the replaced build can only be rebuilt.

## webR image

`ghcr.io/r-wasm/webr:<WEBR_VERSION>` carries the Emscripten toolchain (from
`ghcr.io/r-wasm/flang-wasm`), webR's R, the native R that drives the build, and
rwasm. None of them are pinned separately. The R version decides the binaries'
path, `bin/emscripten/contrib/<r-version>/`, and which webR versions can load
them.

| webR | R |
|---|---|
| v0.5.0 | 4.5.0 |
| v0.5.1 to v0.5.9 | 4.5.1 |
| v0.6.0 | 4.6.0 |

`WEBR_VERSION` appears in:

- `.env.example` (copied to `.env`) and the default in `compose.yaml`
- the `webr_version` inputs and their fallbacks in `.github/workflows/build.yml`
- [`examples/production.env`](examples/production.env) and the examples in
  [`examples/README.md`](examples/README.md)
- [`demo/index.html`](../demo/index.html), together with the `BIOC_VERSION`
  it installs from; the two must target the same R version

The documentation also names the version in commands and examples. List every
occurrence of the current version, and leave statements about what a given
webR release contains unchanged:

```bash
git grep -n 'v0\.6\.0'
```

Check what an image contains:

```bash
docker compose run --rm --entrypoint bash build -c '
  echo "webR R: $(cat /opt/webr/R/R-VERSION)"
  emcc --version | head -n1
  R --version | head -n1
  Rscript -e "cat(\"rwasm\", as.character(packageVersion(\"rwasm\")), \"\n\")"'
```

Procedure: follow the bump procedure in
[operations.md](operations.md#webr_version-is-not-a-preference), then run a
full build of the release the new image is for. Releases for other R versions
keep the image they were built with.

Check: `scripts/publish.sh --check-only` passes on the full build, and a
package from the published release installs in a browser running the matching
webR (see [examples](examples/README.md)).

Rollback: set `WEBR_VERSION` back. A release already published with the new
image has to be rebuilt with the old one and republished.

## Build helper images

| Pin | Where | Used by |
|---|---|---|
| `RCLONE_VERSION` | `.env.example`, [`examples/production.env`](examples/production.env), `compose.yaml` | `publish` |
| `NGINX_VERSION` | `.env.example`, `compose.yaml` | `serve` |
| `debian:12-slim` | `compose.yaml` | `verify`, `export` |
| `r-base:4.4.2` | `lint.yml`, `CONTRIBUTING.md`, `development.md` | R syntax check |

Procedure: change the tag, then run a subset build in a separate Compose
project, `bioc-webr-test`, so it starts from an empty volume and leaves
`bioc-webr_repo` untouched, and run each service on it:

```bash
docker compose config --quiet
BIOC_PACKAGES=BiocGenerics docker compose -p bioc-webr-test run --rm build
docker compose -p bioc-webr-test run --rm verify    # must fail, on the INCOMPLETE marker and the package count only
docker compose -p bioc-webr-test --profile export run --rm export
docker compose -p bioc-webr-test --profile serve up -d serve
curl -sf http://localhost:8080/bin/emscripten/contrib/<r-version>/PACKAGES | head -n 3
docker compose -p bioc-webr-test --profile serve down --volumes
```

For `RCLONE_VERSION`, also run `scripts/publish.sh --dry-run` against the real
remote. It needs a full build without an `INCOMPLETE` marker in
`bioc-webr_repo`.

Rollback: revert the change.

## GitHub Actions

| Action | Pinned to |
|---|---|
| `actions/checkout` | Major tag, `v5` |
| `actions/upload-artifact` | Major tag, `v4` |
| `ludeeus/action-shellcheck` | Commit SHA, with the release in a comment |

Check for newer releases, with an authenticated `gh`:

```bash
for a in actions/checkout actions/upload-artifact ludeeus/action-shellcheck; do
  printf '%s %s\n' "$a" "$(gh api "repos/$a/releases/latest" -q .tag_name)"
done
gh api repos/ludeeus/action-shellcheck/commits/<tag> -q .sha   # the SHA to pin
```

Procedure: update the tag, or the SHA and its comment, in a pull request. The
lint workflow runs on the pull request. Exercise `build.yml` with a subset build
from the Actions tab (`workflow_dispatch` with `packages: BiocGenerics`). The
run fails at its Summarise step, which reads a directory the build does not
write ([deployment.md](deployment.md#the-reusable-workflow)); check that the
steps before it passed.

Rollback: revert the change.

## Self-hosted runner

The runner installed in [deployment.md](deployment.md#self-hosted-runner)
updates itself when a new `actions/runner` release is published, as long as it
can reach GitHub. Its version and status are on the **Settings → Actions →
Runners** page of the repository or organisation it is registered on.

Procedure, for a runner that has fallen behind: stop and uninstall the service
(`sudo ./svc.sh stop && sudo ./svc.sh uninstall`), remove the registration
(`./config.sh remove --token <from the runner settings>`), move the
`actions-runner` directory aside, then install the new release as in
[deployment.md](deployment.md#self-hosted-runner).

Check: the runner shows as idle on the Runners page, with the new version.

Rollback: install the previous release the same way, adding `--disableupdate`
to `config.sh`; without it the runner updates itself to the latest release.
GitHub stops queuing jobs for a runner that is not updated within 30 days of a
new release.

## Hosting images

| Image | Where | Updated |
|---|---|---|
| `rclone/rclone:latest` | `deploy/20-webr.yaml`, init container | Pulled on every pod start |
| `rocker/r-ver:latest` | `deploy/20-webr.yaml`, server | Pulled on every pod start |
| httpuv | Installed from Posit Package Manager by the server | On every pod start |
| `nginx:1.29-alpine` | `deploy/40-webr-repl.yaml` | When the tag is changed |
| webR on the REPL page | `deploy/repl-files/index.html` | `latest`; the page does not start ([known limitations](deployment.md#known-limitations)) |

`latest` tags change without a change here; see
[deployment.md](deployment.md#known-limitations).

Procedure for a template change: edit `deploy/`, review the rendered output,
then apply:

```bash
kubectl kustomize deploy/ | less
kubectl apply -k deploy/
kubectl -n webr-repl rollout status deploy/webr-repl
kubectl -n webr rollout status deploy/webr-deployment --timeout=24h
```

Any change to the `webr-deployment` pod template restarts it, and the restart
copies every release again: the site is unavailable for hours.

Check: the [health checks](operations.md#health-checks).

Rollback: revert the template change and apply it. For a change to an image or
a pod template, `rollout undo` also returns to the previous revision:

```bash
kubectl -n webr-repl rollout undo deploy/webr-repl
kubectl -n webr rollout undo deploy/webr-deployment
```

It does not undo a change to `deploy/repl-files/`: the ConfigMaps keep their
names, so the previous revision mounts the changed files. Revert those files,
then `kubectl apply -k deploy/` and
`kubectl -n webr-repl rollout restart deploy/webr-repl`.

## k3s, Traefik and cert-manager

The templates need:

- Kubernetes with `networking.k8s.io/v1` Ingress.
- Traefik with the `traefik.io/v1alpha1` `Middleware` CRD.
- cert-manager, issuing certificates from the
  `cert-manager.io/cluster-issuer` annotation on each Ingress.

These are cluster components shared with other services. Kubernetes publishes a
minor version about every four months and supports each for about fourteen;
upgrade before the running version's end of support, one minor version at a
time.

Check the running versions:

```bash
kubectl version
kubectl get nodes -o wide
kubectl -n kube-system get deploy traefik \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl get deploy -A -l app.kubernetes.io/instance=cert-manager \
  -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

Procedure:

1. Back up the k3s datastore: `k3s etcd-snapshot save` on a server node for
   embedded etcd, or a copy of `/var/lib/rancher/k3s/server/db/` for SQLite.
   Keep the server token, `/var/lib/rancher/k3s/server/token`, with it: a
   restore needs the same token. The backup holds every Secret in the cluster,
   including other services' credentials and TLS keys, so store it encrypted,
   readable only by cluster operators, and delete it once the upgrade is
   confirmed.
2. Upgrade k3s on the server nodes, then on the agents, to the next minor
   version, following the
   [k3s upgrade documentation](https://docs.k3s.io/upgrades). The Traefik that
   k3s packages is upgraded with k3s. Restarting or draining the node that
   runs `webr-deployment` restarts it, with the hours-long copy.
3. Upgrade cert-manager with the method it was installed with, one minor
   version at a time, after reading its
   [upgrade notes](https://cert-manager.io/docs/releases/).

Check:

```bash
kubectl get nodes
kubectl -n webr get pods,certificate
kubectl -n webr-repl get pods,certificate
```

then the [health checks](operations.md#health-checks).

Rollback: Kubernetes does not support downgrading a minor version. Restore the
datastore snapshot taken in step 1, following the k3s documentation for the
datastore in use.
