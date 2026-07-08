#!/usr/bin/env bash
# Empaquette Beam-RemotePlus-Mod/src/ en zip prêt à déployer dans le dossier
# mods/ de BeamNG.drive. Sortie dans dist/ ET dans ../Package/.
# Déploie également dans le dossier mods BeamNG local si présent.
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$MOD_DIR/src"
DIST_DIR="$MOD_DIR/dist"
PACKAGE_DIR="$(cd "$MOD_DIR/.." && pwd)/Package"
BEAMNG_MODS_DIR="$HOME/.local/share/BeamNG/BeamNG.drive/current/mods/repo"
OUT_ZIP="$DIST_DIR/Beam-RemotePlus.zip"
PKG_ZIP="$PACKAGE_DIR/Beam-RemotePlus.zip"

mkdir -p "$DIST_DIR" "$PACKAGE_DIR"
rm -f "$OUT_ZIP"

cd "$SRC_DIR"
zip -r -X "$OUT_ZIP" lua scripts settings mod_info >/dev/null

cp "$OUT_ZIP" "$PKG_ZIP"

echo "Mod compilé: $OUT_ZIP"
echo "Copié dans:  $PKG_ZIP"

if [[ -d "$BEAMNG_MODS_DIR" ]]; then
  cp "$OUT_ZIP" "$BEAMNG_MODS_DIR/Beam-RemotePlus.zip"
  echo "Déployé:     $BEAMNG_MODS_DIR/Beam-RemotePlus.zip"
  # Crée le trigger de hot-reload : si BeamNG tourne déjà avec le mod actif,
  # l'extension le détecte dans les 3 s et recharge automatiquement le zip
  # sans passer par le gestionnaire de mods (désactiver/réactiver).
  touch "$BEAMNG_MODS_DIR/Beam-RemotePlus-reload.trigger"
  echo "Trigger:     $BEAMNG_MODS_DIR/Beam-RemotePlus-reload.trigger"
fi
