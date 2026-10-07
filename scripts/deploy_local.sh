#!/usr/bin/env bash
# Developer helper: builds the mod and copies it into the local BeamNG user
# mods folder, then creates the hot-reload trigger so a running game picks
# up the new code within ~3 s (see src/lua/ge/extensions/beamRemotePlus/devReload.lua).
#
# Usage: scripts/deploy_local.sh [beamng-user-folder]
#   default user folder: ~/.local/share/BeamNG/BeamNG.drive/current (Linux/Proton)
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_DIR="${1:-$HOME/.local/share/BeamNG/BeamNG.drive/current}"
MODS_DIR="$USER_DIR/mods/repo"

if [[ ! -d "$MODS_DIR" ]]; then
  echo "error: $MODS_DIR does not exist (is BeamNG installed? pass the user folder as argument)" >&2
  exit 1
fi

"$MOD_DIR/scripts/build_mod.sh"
cp "$MOD_DIR/dist/Beam-RemotePlus.zip" "$MODS_DIR/Beam-RemotePlus.zip"
touch "$MODS_DIR/Beam-RemotePlus-reload.trigger"
echo "Deployed to $MODS_DIR (hot-reload trigger created)"
