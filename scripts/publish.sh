#!/bin/bash
#
# Publish a built repository to the object store.
#
#   scripts/publish.sh [--check-only] [--dry-run] [--force]
#
# Host-side orchestration only. The real work happens in containers:
#
#   1. `verify` runs scripts/verify_site.sh against the built tree
#   2. `publish` runs rclone sync against the same tree
#
# Step 1 is the point. `rclone sync` DELETES remote files that are absent
# locally, so publishing a half-built tree does not merely fail to add
# packages - it destroys the working repository already published under that
# version. verify_site.sh is the only thing standing between a failed
# build and a wrecked remote.
#
#   --check-only  verify and stop. Safe to run at any time
#   --dry-run     verify, then rclone --dry-run. Shows what would change
#   --force       publish despite failed checks. Requires typing the version
#
# See docs/operations.md.

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CHECK_ONLY=0
DRY_RUN=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --force)      FORCE=1 ;;
    -h|--help)    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# .env is the normal source of configuration; Compose reads it too.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

: "${BIOC_VERSION:?BIOC_VERSION is not set. Copy .env.example to .env}"

# ---------------------------------------------------------------- verify
if docker compose run --rm verify; then
  VERIFIED=1
else
  VERIFIED=0
fi

if [ "$VERIFIED" -ne 1 ]; then
  echo ""
  if [ "$FORCE" -ne 1 ]; then
    echo "Refusing to publish."
    echo ""
    echo "rclone sync deletes remote files that are absent locally, so"
    echo "publishing this tree would damage the published ${BIOC_VERSION}"
    echo "repository rather than just failing to improve it."
    echo ""
    echo "Rebuild, or re-run with --force if you are certain."
    exit 1
  fi
  echo "--force given. Type the Bioconductor version to confirm you intend to"
  echo "overwrite the published ${BIOC_VERSION} repository with this tree:"
  read -r -p "  version: " CONFIRM
  if [ "$CONFIRM" != "$BIOC_VERSION" ]; then
    echo "Did not match. Aborting."
    exit 1
  fi
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo ""
  echo "(--check-only: not publishing)"
  exit 0
fi

# ---------------------------------------------------------------- publish
: "${RCLONE_REMOTE:?RCLONE_REMOTE is not set, e.g. js2:/webr}"
: "${RCLONE_CONFIG_DIR:?RCLONE_CONFIG_DIR is not set - absolute path to the directory holding rclone.conf}"

case "$RCLONE_CONFIG_DIR" in
  /*) ;;
  *) echo "RCLONE_CONFIG_DIR must be an absolute path (Compose does not expand ~)" >&2; exit 2 ;;
esac

SRC="/repo/${BIOC_VERSION}/_site"
DEST="${RCLONE_REMOTE}/${BIOC_VERSION}"

echo ""
echo "Publishing ${SRC}"
echo "       to  ${DEST}"

# Arguments are passed explicitly so the destination this script checked is
# the destination rclone is given.
RCLONE_ARGS=(sync --verbose --checksum)
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "(--dry-run: no remote changes)"
  RCLONE_ARGS+=(--dry-run)
fi
RCLONE_ARGS+=("$SRC" "$DEST")

docker compose --profile publish run --rm publish "${RCLONE_ARGS[@]}"

echo ""
echo "Done."
