# Contributing

## Before you start

Read [docs/development.md](docs/development.md). It covers setup, the fast
iteration loop, and the three things that will otherwise bite you (a macOS
bind-mount permission failure, an upstream rwasm resolution bug, and GitHub API
rate limits).

## Where things belong

**All logic lives in `scripts/`. `compose.yaml` only wires it up.**

If you are about to write something non-trivial inside a compose `command:`
string or a workflow `run:` block, it belongs in a script instead — those can be
linted, syntax-checked, and read comfortably. The one exception is the `export`
service's copy, which is three lines and has nowhere better to live.

The same rule explains the workflow: `.github/workflows/build.yml` writes a
`.env` and calls the same compose services you run locally. There is no CI-only
build path, because a CI-only path drifts out of sync with what anyone can
reproduce.

## Checks before opening a pull request

```bash
# Shell scripts parse
for f in scripts/*.sh; do bash -n "$f" || echo "FAILED: $f"; done

# R parses
docker run --rm -v "$PWD:/w:ro" -w /w r-base:4.4.2 \
  Rscript -e 'invisible(parse("scripts/build_repo.R")); cat("ok\n")'

# Compose is valid, with no interpolation warnings
docker compose config --quiet

# A subset build works end to end
docker volume rm bioc-webr_repo 2>/dev/null || true
docker compose run --rm build

# ...and verification correctly REFUSES it
docker compose run --rm verify   # must exit non-zero
```

CI runs the first three on every pull request. The build is yours to run.

## Say what you tested

A full Bioconductor release is thousands of packages and hours of compute. No
reviewer can reasonably ask you to run one, which means **the pull request
description is the only evidence anyone has**. Be specific:

> Tested: subset build (`BIOC_PACKAGES=BiocGenerics S4Vectors`) on macOS and on
> a Linux VM, both clean. Verification correctly refuses the subset output.
> The full-release path is unchanged but I have not run one.

versus

> Tested locally.

The second tells a reviewer nothing: it does not say whether the subset path or
a full release was exercised.

If you did run a full build, say how long it took and how many packages it
produced — that number is useful to the next person, and belongs in
`MIN_PACKAGES`.

## Style

- **Comments explain why, not what.** The code says what it does. A comment
  earns its place by recording a decision, a constraint, or a trap — the reason
  the build uses a named volume, the reason `pathlist` contains itself.
- **Mark behaviour that consumers depend on.** Some behaviour is odd because
  consumers depend on it, such as the shape of `pathlist`, which the hosting
  reads. Those are marked in the code. Changing one is a decision, not a
  cleanup.
- **Fail loudly.** A build that quietly produces less than it should is worse
  than one that stops. This is why the remotes filter reports what it dropped,
  why a zero-package build is an error, and why `verify` exists at all.
- `set -euo pipefail` in every shell script.

## Changing pinned versions

[docs/updating.md](docs/updating.md) has the procedure, checks and rollback
for every pin, including the hosting templates in `deploy/`.

`WEBR_VERSION` is a compatibility contract, not a preference — a webR release
fixes the ABI of every `.wasm` it produces. Read
[docs/operations.md](docs/operations.md#webr_version-is-not-a-preference) before
touching it, and follow the bump procedure there.

Other pins (`RCLONE_VERSION`, `NGINX_VERSION`, the `debian:12-slim` used by
`verify` and `export`) are ordinary and can be bumped with a passing subset
build.

## Reporting a problem

Include:

- the `BUILDINFO` file if a build produced one
- `WEBR_VERSION` and `BIOC_VERSION`
- whether it was a subset or full build
- the host OS — the macOS bind-mount failure in
  [docs/troubleshooting.md](docs/troubleshooting.md) is platform-specific and
  the error message points nowhere near the cause

Security issues: do not open a public issue. See
[docs/security.md](docs/security.md#reporting-a-vulnerability).
