#!/usr/bin/env bash
# Packages src/ into dist/Beam-RemotePlus.zip, ready for BeamNG's mods/ folder.
#
# Usage: scripts/build_mod.sh [version]
#   version (the release tag, e.g. v0.0.3, a leading "v" is stripped) is
#   written into server.lua and the UI app (both say "dev" in the sources);
#   the release workflow passes the tag. Without it the sources are packaged
#   as they are. The archive is reproducible: fixed timestamps, sorted entries.
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$MOD_DIR/dist"
STAGE_DIR="$DIST_DIR/stage"
OUT_ZIP="$DIST_DIR/Beam-RemotePlus.zip"
VERSION="${1:-}"
VERSION="${VERSION#v}"

mkdir -p "$DIST_DIR"
rm -rf "$STAGE_DIR" "$OUT_ZIP"
cp -r "$MOD_DIR/src" "$STAGE_DIR"

if [[ -n "$VERSION" ]]; then
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "error: '$VERSION' is not a semantic version" >&2
    exit 1
  fi
  sed -i -E "s/\"version\": \"[^\"]*\"/\"version\": \"$VERSION\"/" "$STAGE_DIR/ui/modules/apps/BeamRemotePlus/app.json"
  sed -i -E "s/^M\.VERSION = '[^']*'/M.VERSION = '$VERSION'/" "$STAGE_DIR/lua/ge/extensions/beamRemotePlus/server.lua"
fi

# Fixed mtime (2020-01-01) so identical sources give a byte-identical zip.
find "$STAGE_DIR" -exec touch -h -d '2020-01-01T00:00:00Z' {} +
(cd "$STAGE_DIR" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -X -q -9 "$OUT_ZIP" -@)
rm -rf "$STAGE_DIR"

echo "Built $OUT_ZIP ($(du -h "$OUT_ZIP" | cut -f1))"
