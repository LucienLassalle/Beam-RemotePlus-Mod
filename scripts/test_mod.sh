#!/usr/bin/env bash
# Lance les tests unitaires du mod (logique pure, sans BeamNG.drive).
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v luajit >/dev/null 2>&1; then
  echo "Erreur: luajit introuvable." >&2
  exit 1
fi

cd "$MOD_DIR"
luajit test/protocol_test.lua
