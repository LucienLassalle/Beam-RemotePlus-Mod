#!/usr/bin/env bash
# Empaquette Beam-RemotePlus-Mod/src/ en zip prêt à déployer dans le dossier
# mods/ de BeamNG.drive.
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$MOD_DIR/src"
DIST_DIR="$MOD_DIR/dist"
OUT_ZIP="$DIST_DIR/Beam-RemotePlus.zip"

mkdir -p "$DIST_DIR"
rm -f "$OUT_ZIP"

cd "$SRC_DIR"
zip -r -X "$OUT_ZIP" lua scripts settings >/dev/null

echo "Mod compilé: $OUT_ZIP"
