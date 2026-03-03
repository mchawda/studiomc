#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_macos.sh — Full macOS production build (convenience wrapper)
#
# Delegates to the canonical pipeline in scripts/build/ and scripts/release/.
# Kept for backwards compatibility.
#
# Usage:
#   bash scripts/build_macos.sh [--skip-services] [--skip-flutter] [--sign] [--dmg]
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

DO_DMG=false
BUILD_ARGS=()

for arg in "$@"; do
    case $arg in
        --dmg) DO_DMG=true ;;
        --no-dmg) DO_DMG=false ;;
        *) BUILD_ARGS+=("$arg") ;;
    esac
done

bash "$SCRIPT_DIR/build/build_macos.sh" "${BUILD_ARGS[@]}"

if [ "$DO_DMG" = true ]; then
    bash "$SCRIPT_DIR/release/macos_dmg.sh"
fi
