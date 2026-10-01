# Security considerations

This repository compiles third-party source code and publishes the binaries for
browsers to execute.

## What is being trusted

```
Bioconductor release  ─┐
CRAN / Posit PPM      ─┼─► rwasm + Emscripten ─► .wasm binaries ─► users' browsers
rwasm's webR remotes  ─┘        (in a container)      (published)
```

Everything upstream of the build is trusted implicitly. Nothing here verifies
that a source tarball is what its maintainer published, and nothing signs what
comes out. A user installing a package from the published repository is trusting
the whole chain, and this repository is a link in it.

This is the trust model of any binary distribution.

### Sources

| Source | What it supplies | Verified? |
|---|---|---|
| `bioconductor.org/packages/<ver>/bioc/` | The package set | HTTPS only |
| Posit Package Manager | CRAN dependency sources (rwasm's default) | HTTPS only |
| rwasm's `webr-remotes` | GitHub refs to webR-patched forks | HTTPS only |
| `ghcr.io/r-wasm/webr` | Toolchain and rwasm itself | Tag pin, not digest |

**The image is pinned by tag, not by digest.** `ghcr.io/r-wasm/webr:v0.6.0`
could in principle be repushed. Pinning by digest would close that, at the cost
of a less readable pin and a manual step on every upgrade. For a stronger
guarantee:

```yaml
image: ghcr.io/r-wasm/webr@sha256:<digest>
```

### The webR remotes are GitHub branches, not releases

rwasm substitutes package sources from references like `r-wasm/gt@webr` — a
*branch*, which moves. A build today and a build next month can compile
different code from the same reference, and `BUILDINFO` records neither the
commit nor which substitutions were made.

This is upstream behaviour, and it means a build cannot be reproduced from its
`BUILDINFO`. Recording the resolved commit for each substituted package in
`BUILDINFO` would fix the audit trail without changing what is built.

## Publishing credentials

### `rclone.conf`

**Grants** whatever the configured remote allows — for an object store, usually
full read/write on the bucket, including delete.

It is the only secret the build and publish path uses. Publishing is
`rclone sync`, which **deletes remote files absent locally**, so a leaked
credential allows replacing or emptying the published repository, not only
adding packages.

**Handling:**

- Scope the credential to the smallest prefix that works. If the object store
  supports it, restrict to `webr/*` rather than the whole bucket.
- Prefer a credential that cannot delete outside that prefix.
- In CI it is written to `$RUNNER_TEMP` mode 600 and removed in an `always()`
  step. **On a self-hosted runner the file is on a persistent disk**; a runner
  that stops mid-job leaves it there until its next job starts.
- Mounted read-only into the container (`:ro`).
- Rotate it if a build host is ever decommissioned or shared.

### The gate is a security control, not only a safety one

`publish.sh` refuses to publish a tree that fails verification. That guards
against a broken build, and equally against a build that was interrupted,
tampered with, or run against the wrong version — any of which would otherwise
propagate straight to users through a sync that deletes.

`--force` bypasses it and requires typing the version number.

## Build host

**Whoever can trigger a build can run arbitrary code on the build host.** The
build compiles thousands of third-party packages, and compiling a package runs
its configure scripts.

- The container runs as **root** — necessary for the image's R library layout,
  and it means a malicious `configure` runs as root inside the container.
- The container has **network access**, needed to fetch sources.
- A **self-hosted runner on a public repository** runs code from anyone who
  can open a pull request: a pull request from a fork runs the workflows as it
  changes them, including their `runs-on` labels. Register the runner on a
  private calling repository or in a runner group closed to public
  repositories ([deployment.md](deployment.md#self-hosted-runner)), and do
  not put it on a machine that holds anything else.

Reasonable hardening, in order of value:

1. Dedicate the build host. Nothing else on it, nothing else reachable from it.
2. Keep publishing credentials off the build host entirely — build in one place,
   publish from another that only reads the artifact.
3. Restrict the build container's network to the hosts it fetches sources
   from ([Sources](#sources)).

## What the published repository means for users

A webR user installing from this repository executes WebAssembly compiled here,
in their browser.

WebAssembly's sandbox is real and meaningful — no filesystem, no network beyond
what the host page grants, no syscalls. A malicious package cannot read a user's
disk. But it runs with the page's privileges for anything the host *does*
expose, and it can do anything a webR session can: read data loaded into that
session, make requests the page is allowed to make.

The practical guidance is the same as for any R repository: this is as
trustworthy as Bioconductor's package review plus this build pipeline, and no
more.

**No signing, no checksums beyond the `PACKAGES` index.** A user cannot verify
that a `.tgz` came from this pipeline rather than being substituted at the
object store or in transit. Serving over HTTPS covers transit. Signing is not
implemented; it would need support in webR's installer to be useful.

## Hosting

### Trust boundaries

- `webr.bioconductor.org` serves static files from the `webr-pvc` volume. The
  server container (`httpuv::runStaticServer()`) has no credentials mounted.
- The init container holds the object-storage credentials and is the only
  component that talks to object storage with them.
- `run.webr.bioconductor.org` serves static files: a console page and
  `repl.mjs`. Any R code runs in the visitor's browser, with webR loaded from
  `webr.r-wasm.org`.
- Traefik terminates TLS for both hosts; traffic inside the cluster is HTTP.

### Secrets

| Secret | Namespace | Holds | Managed by |
|---|---|---|---|
| `rclone-conf` | `webr` | `rclone.conf` for object storage | The operator, by hand; never committed |
| `webr-bioconductor-org-tls` | `webr` | TLS key and certificate | cert-manager |
| `run-webr-bioconductor-org-tls` | `webr-repl` | TLS key and certificate | cert-manager |
| ClusterIssuer credentials | cert-manager's namespace | DNS provider API credentials, for a DNS-01 issuer | The cluster operator |

The init container only reads object storage. Give `rclone-conf` a read-only
credential where the object store supports one, separate from the publishing
credential described above.

### Hardening in place

- Both hosts redirect HTTP to HTTPS with a permanent redirect.
- `run.webr.bioconductor.org` sends `X-Content-Type-Options: nosniff`.
- Every container has a memory limit, and the serving containers have
  readiness and liveness probes.

### Known gaps

- **Floating versions.** `rclone/rclone:latest`, `rocker/r-ver:latest`, the
  httpuv installed from Posit Package Manager at every start, and webR
  `latest` on the REPL page all change without a change to this repository.
  Each is a supply chain input that is not pinned.
- **The REPL page's Content-Security-Policy blocks the page.** It allows no
  inline script, so the console does not start, and it has no
  `'wasm-unsafe-eval'`; see
  [deployment.md](deployment.md#known-limitations).
- **`repl.mjs` names an unrelated package repository.** It is served but not
  loaded, and sets `https://my-repo.com`, a domain outside Bioconductor's
  control, as webR's first package repository. A page that loads it installs
  WebAssembly packages from that domain.
- **No `securityContext`.** The containers run as their images' default user,
  which is root for `rclone/rclone` and `rocker/r-ver`, and the server
  container mounts the volume read-write.
- **No NetworkPolicy.** Pods in both namespaces can reach anything the cluster
  network allows.
- **No HSTS.** Neither host sends `Strict-Transport-Security`.

## Excluded by design

- **No secrets in the repository.** `.env` is gitignored; `.env.example`
  contains no real values.
- **No `pull_request_target` or similar trigger.** The build workflow runs on
  `workflow_call` and `workflow_dispatch` only. A trigger that ran branch
  content with repository secrets in scope would hand the publishing credential
  to anyone who could open a pull request.
- **No self-hosted runner on this repository.** The lint workflow runs on
  `pull_request`, and a pull request from a fork can change it, or add a
  workflow, to run on any runner registered here.
- **Publishing is not scheduled.** A maintainer starts every publish, so no
  scheduled job overwrites a live repository with an unreviewed build.

## Reporting a vulnerability

Do not open a public issue. Email the Bioconductor core team at
[bioconductorcoreteam@gmail.com](mailto:bioconductorcoreteam@gmail.com), the
address listed at <https://bioconductor.org/about/>.
