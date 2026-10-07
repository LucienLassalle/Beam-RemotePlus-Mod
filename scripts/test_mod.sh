#!/usr/bin/env bash
# Runs the mod unit tests (pure Lua, no BeamNG.drive needed).
set -euo pipefail

MOD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v luajit >/dev/null 2>&1; then
  echo "error: luajit not found (BeamNG runs LuaJIT 2.1, use the same)." >&2
  exit 1
fi

luajit "$MOD_DIR/test/run.lua"
