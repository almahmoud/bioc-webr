#!/bin/bash
#
# Decide whether a built repository is fit to publish.
#
#   docker compose run --rm verify
#
# Runs inside the `verify` container so GNU find/grep/stat match the tools
# that built the tree. Exits 0 if the tree is publishable, 1 otherwise;
# scripts/publish.sh runs this first and refuses to publish on a non-zero
# exit.
#
# Publishing is `rclone sync`, which DELETES remote files absent locally, so
# a half-built tree must never reach it.

set -uo pipefail

SITE_DIR="${SITE_DIR:?SITE_DIR is required}"
BIOC_VERSION="${BIOC_VERSION:?BIOC_VERSION is required}"
MIN_PACKAGES="${MIN_PACKAGES:-500}"

FAILURES=0
ok()   { printf '  [ ok ] %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

echo "Verifying ${SITE_DIR} (Bioconductor ${BIOC_VERSION})"
echo ""

# ---------------------------------------------------------------- structure
if [ ! -d "$SITE_DIR" ]; then
  bad "$SITE_DIR does not exist - nothing has been built"
  echo ""
  echo "Run: docker compose run --rm build"
  exit 1
fi
ok "repository directory exists"

if [ -f "${SITE_DIR}/INCOMPLETE" ]; then
  bad "INCOMPLETE marker present - this is a development subset build"
  sed 's/^/         /' "${SITE_DIR}/INCOMPLETE"
else
  ok "no INCOMPLETE marker"
fi

if [ -f "${SITE_DIR}/BUILDINFO" ]; then
  BUILT=$(awk '/^bioc_version:/ {print $2}' "${SITE_DIR}/BUILDINFO")
  if [ "$BUILT" = "$BIOC_VERSION" ]; then
    ok "BUILDINFO records Bioconductor ${BUILT}"
  else
    bad "BUILDINFO records ${BUILT}, but BIOC_VERSION is ${BIOC_VERSION}"
  fi
else
  bad "BUILDINFO missing - the build did not run to completion"
fi

# ---------------------------------------------------------------- contents
#
# rwasm lays the repository out CRAN-style:
#   <site>/src/contrib/                    source tarballs
#   <site>/bin/emscripten/contrib/<Rver>/  .tgz binaries and the PACKAGES index
shopt -s nullglob
PACKAGES_FILES=("${SITE_DIR}"/bin/emscripten/contrib/*/PACKAGES)
shopt -u nullglob

INDEXED=""
if [ ${#PACKAGES_FILES[@]} -eq 0 ]; then
  bad "no bin/emscripten/contrib/*/PACKAGES index - webR cannot use this tree"
else
  for p in "${PACKAGES_FILES[@]}"; do
    if [ -s "$p" ]; then
      INDEXED=$(grep -c '^Package:' "$p")
      ok "$(dirname "${p#"${SITE_DIR}"/}") indexes ${INDEXED} packages"
    else
      bad "${p#"${SITE_DIR}"/} is empty"
    fi
  done
fi

BIN_TGZ=$(find "${SITE_DIR}" -path '*/bin/emscripten/*' -name '*.tgz' -type f | wc -l)
if [ "$BIN_TGZ" -ge "$MIN_PACKAGES" ]; then
  ok "${BIN_TGZ} binary packages (minimum ${MIN_PACKAGES})"
else
  bad "${BIN_TGZ} binary packages, expected at least ${MIN_PACKAGES}"
fi

# An index that disagrees with the disk hands webR packages it cannot fetch.
if [ -n "$INDEXED" ]; then
  if [ "$INDEXED" -eq "$BIN_TGZ" ]; then
    ok "PACKAGES index matches the ${BIN_TGZ} binaries on disk"
  else
    bad "PACKAGES lists ${INDEXED} packages but ${BIN_TGZ} .tgz files are present"
  fi
fi

# ---------------------------------------------------------------- listing
for f in pathlist index.html; do
  if [ -s "${SITE_DIR}/${f}" ]; then
    ok "${f} present"
  else
    bad "${f} missing or empty - make_index.sh did not run"
  fi
done

if [ -s "${SITE_DIR}/pathlist" ]; then
  BAD_PREFIX=$(grep -cv "^${BIOC_VERSION}/" "${SITE_DIR}/pathlist")
  if [ "$BAD_PREFIX" -eq 0 ]; then
    ok "every pathlist entry is prefixed ${BIOC_VERSION}/"
  else
    bad "${BAD_PREFIX} pathlist entries are not prefixed ${BIOC_VERSION}/"
  fi
fi

# ---------------------------------------------------------------- verdict
echo ""
if [ "$FAILURES" -gt 0 ]; then
  echo "${FAILURES} check(s) failed. This tree is NOT publishable."
  exit 1
fi
echo "All checks passed. Size: $(du -sh "${SITE_DIR}" | cut -f1)"
exit 0
