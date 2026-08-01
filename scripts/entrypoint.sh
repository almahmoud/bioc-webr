#!/bin/bash
#
# Container-side build driver; assumes the r-wasm/webr image's toolchain and
# the mounts from compose.yaml.
#
# Phases:
#   1. cross-compile the Bioconductor package set   (build_repo.R)
#   2. generate pathlist and index.html             (make_index.sh)
#   3. restore ownership to the invoking user       (chown)
#
# Phase 3 is why the container runs as root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${BIOC_VERSION:?BIOC_VERSION is required}"
: "${BIOC_REPO_URL:?BIOC_REPO_URL is required}"

SITE_DIR="${SITE_DIR:-/site}"
LOG_DIR="${LOG_DIR:-/logs}"

mkdir -p "$SITE_DIR" "$LOG_DIR"

# Restore ownership on any exit; a failed build must not leave a root-owned
# tree the invoking user cannot delete.
finish() {
  local status=$?
  if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID}" "$SITE_DIR" "$LOG_DIR" 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ]; then
    echo ""
    echo "Build FAILED (exit $status)."
    echo "Logs: ${LOG_DIR}/"
    echo "Partial output left in ${SITE_DIR}/ - it is NOT safe to publish."
    echo "See docs/troubleshooting.md."
  fi
  return $status
}
trap finish EXIT

echo "=============================================================="
echo " Bioconductor webR repository build"
echo "=============================================================="
echo "  Bioconductor release : ${BIOC_VERSION}"
echo "  Source repository    : ${BIOC_REPO_URL}"
# webR's R version is also the directory name under bin/emscripten/contrib/.
echo "  webR R version       : $(cat "${WEBR_ROOT:-/opt/webr}/R/R-VERSION" 2>/dev/null || echo 'unknown')"
echo "  R (native, driver)   : $(R --version 2>/dev/null | head -n1 || echo 'unknown')"
echo "  Output               : ${SITE_DIR}"
echo "  Ncpus                : ${BUILD_JOBS:-2}"
echo "=============================================================="
echo ""

# ---------------------------------------------------------------- phase 1
echo "[1/3] Cross-compiling packages. This takes hours for a full release."
Rscript "${SCRIPT_DIR}/build_repo.R" 2>&1 | tee "${LOG_DIR}/build.log"

# Rscript's status, not tee's.
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "build_repo.R failed; see ${LOG_DIR}/build.log"
  exit 1
fi

# ---------------------------------------------------------------- phase 2
echo ""
echo "[2/3] Generating pathlist and index.html"
BIOC_VERSION="$BIOC_VERSION" bash "${SCRIPT_DIR}/make_index.sh" "$SITE_DIR"

# ---------------------------------------------------------------- phase 3
echo ""
echo "[3/3] Restoring ownership to ${HOST_UID:-?}:${HOST_GID:-?}"

echo ""
echo "Build complete."
echo "  Packages: $(find "$SITE_DIR" -name '*.tgz' 2>/dev/null | wc -l | tr -d ' ')"
echo "  Size:     $(du -sh "$SITE_DIR" 2>/dev/null | cut -f1)"
echo ""
echo "Verify before publishing:  scripts/publish.sh --check-only"
