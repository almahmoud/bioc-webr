#!/bin/bash
#
# Generate `pathlist` and `index.html` for a built repository.
#
#   make_index.sh <site_dir>
#
# BIOC_VERSION must be set: every path in `pathlist` is prefixed with it,
# because the published tree lives under <remote>/<version>/ and the listing
# is consumed relative to the bucket root.
#
# `pathlist` is generated before `index.html`, so the listing contains
# `pathlist` but not `index.html`. Consumers may depend on that shape.

set -euo pipefail

SITE_DIR="${1:?usage: make_index.sh <site_dir>}"
: "${BIOC_VERSION:?BIOC_VERSION is required}"

if [ ! -d "$SITE_DIR" ]; then
  echo "error: $SITE_DIR does not exist" >&2
  exit 1
fi

PATHLIST="${SITE_DIR}/pathlist"
INDEX="${SITE_DIR}/index.html"

# Remove any previous run's artifacts first so they are not listed as content.
rm -f "$PATHLIST" "$INDEX"

echo "Generating ${PATHLIST}"

# Create pathlist empty before walking the tree so it appears in its own
# listing; consumers may rely on that.
: > "$PATHLIST"

# Sorted for a stable, diffable listing; `find` order depends on the filesystem.
TMPLIST="$(mktemp)"
trap 'rm -f "$TMPLIST"' EXIT

find "$SITE_DIR" -type f -print \
  | sed "s#^${SITE_DIR}/#${BIOC_VERSION}/#" \
  | LC_ALL=C sort \
  > "$TMPLIST"

cat "$TMPLIST" > "$PATHLIST"

COUNT=$(wc -l < "$PATHLIST" | tr -d ' ')
echo "  ${COUNT} paths"

echo "Generating ${INDEX}"
{
  cat <<'HTML'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Path Index</title>
</head>
<body>
HTML

  while IFS= read -r line; do
    # Escape & first, or the entities introduced below get double-escaped.
    esc=${line//&/&amp;}
    esc=${esc//</&lt;}
    esc=${esc//>/&gt;}
    esc=${esc//\"/&quot;}
    printf '<a href="%s">%s</a><br>\n' "$esc" "$esc"
  done < "$PATHLIST"

  cat <<'HTML'
</body>
</html>
HTML
} > "$INDEX"

echo "  ${INDEX} written"
