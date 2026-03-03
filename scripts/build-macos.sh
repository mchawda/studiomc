#!/usr/bin/env bash
# ─── Studiomc macOS Build + DMG (convenience wrapper) ─────────────
#
# Wraps the canonical build pipeline:
#   1. scripts/build/build_macos.sh  — services + Flutter + embed
#   2. scripts/release/macos_dmg.sh  — package into .dmg
#
# Usage:
#   ./scripts/build-macos.sh              # Full build + DMG
#   ./scripts/build-macos.sh --skip-services  # Reuse services bundle
#
# Output: dist/Studiomc-<version>-macOS.dmg
# ────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Forward all arguments to the canonical build script
bash "$SCRIPT_DIR/build/build_macos.sh" "$@"

# Then create the DMG
bash "$SCRIPT_DIR/release/macos_dmg.sh"
