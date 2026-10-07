#!/usr/bin/env bash
# Developer helper: builds the mod and copies it into the local BeamNG user
# mods folder, then creates the hot-reload trigger so a running game picks
# up the new code within ~3 s (see src/lua/ge/extensions/beamRemotePlus/devReload.lua).
#
# Usage: scripts/deploy_local.sh [beamng-user-folder]
#   default: the Proton prefix of the Steam game (Windows build on Linux),
#   then the native Linux user folder.
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
find_user_dir() {
  local suffix="steamapps/compatdata/284160/pfx/drive_c/users/steamuser/AppData/Local/BeamNG/BeamNG.drive/current"
  local libraries
  libraries="$(grep -o '"path"[[:space:]]*"[^"]*"' "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" 2>/dev/null | cut -d'"' -f4)"
  for lib in $libraries "$HOME/.local/share/Steam"; do
    [[ -d "$lib/$suffix" ]] && { echo "$lib/$suffix"; return; }
  done
  echo "$HOME/.local/share/BeamNG/BeamNG.drive/current"
}

USER_DIR="${1:-$(find_user_dir)}"
MODS_DIR="$USER_DIR/mods/repo"

if [[ ! -d "$MODS_DIR" ]]; then
  echo "error: $MODS_DIR does not exist (is BeamNG installed? pass the user folder as argument)" >&2
  exit 1
fi

"$MOD_DIR/scripts/build_mod.sh"
cp "$MOD_DIR/dist/Beam-RemotePlus.zip" "$MODS_DIR/Beam-RemotePlus.zip"
touch "$MODS_DIR/Beam-RemotePlus-reload.trigger"
echo "Deployed to $MODS_DIR (hot-reload trigger created)"
