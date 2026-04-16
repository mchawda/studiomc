#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_app.sh — Platform-agnostic build (services + Flutter + embed)
#
# Detects the current OS and delegates to the platform-specific build.
# Used by Makefile targets that don't specify a platform explicitly
# (e.g. make build-app, make build-linux).
#
# Usage:
#   bash scripts/build/build_app.sh [--skip-services] [--skip-flutter] [--clean]
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"
SERVICES_DIR="$PROJECT_ROOT/services"

SKIP_SERVICES=false
SKIP_FLUTTER=false
CLEAN=false

for arg in "$@"; do
    case $arg in
        --skip-services) SKIP_SERVICES=true ;;
        --skip-flutter)  SKIP_FLUTTER=true ;;
        --clean)         CLEAN=true ;;
    esac
done

OS="$(uname -s)"

case "$OS" in
    Darwin)
        echo "Detected macOS — delegating to build_macos.sh"
        exec bash "$SCRIPT_DIR/build_macos.sh" "$@"
        ;;
    Linux)
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║  Studiomc — Linux Production Build                  ║"
        echo "╚══════════════════════════════════════════════════════╝"
        echo ""

        SERVICES_BUNDLE="$SERVICES_DIR/dist/studiomc_services"

        # Step 1: Build services
        if [ "$SKIP_SERVICES" = true ]; then
            echo "⊘ Skipping services build (--skip-services)"
            if [ ! -d "$SERVICES_BUNDLE" ]; then
                echo "✗ Services bundle not found at $SERVICES_BUNDLE"
                exit 1
            fi
        else
            CLEAN_ARG=""
            if [ "$CLEAN" = true ]; then CLEAN_ARG="--clean"; fi
            bash "$SCRIPT_DIR/build_services.sh" $CLEAN_ARG
        fi

        # Step 2: Build Flutter
        if [ "$SKIP_FLUTTER" = true ]; then
            echo "⊘ Skipping Flutter build (--skip-flutter)"
        else
            if [ "$CLEAN" = true ]; then
                cd "$FLUTTER_DIR" && flutter clean
            fi
            cd "$FLUTTER_DIR"
            flutter build linux --release
            echo "✓ Flutter Linux build complete"
        fi

        # Step 3: Embed services
        BUNDLE_DIR="$FLUTTER_DIR/build/linux/x64/release/bundle"
        if [ ! -d "$BUNDLE_DIR" ]; then
            echo "✗ Flutter Linux build not found at $BUNDLE_DIR"
            exit 1
        fi

        SERVICES_DEST="$BUNDLE_DIR/studiomc_services"
        if [ -d "$SERVICES_DEST" ]; then rm -rf "$SERVICES_DEST"; fi
        cp -R "$SERVICES_BUNDLE" "$SERVICES_DEST"
        chmod +x "$SERVICES_DEST/studiomc_services" 2>/dev/null || true
        echo "✓ Services embedded into Linux bundle"

        echo ""
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║  ✓ Linux build complete                             ║"
        echo "╠══════════════════════════════════════════════════════╣"
        echo "║  Bundle: $BUNDLE_DIR"
        echo "╚══════════════════════════════════════════════════════╝"
        echo ""
        echo "Next steps:"
        echo "  • AppImage: bash scripts/release/linux_appimage.sh"
        echo "  • Test:     $BUNDLE_DIR/studiomc_app"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Detected Windows — use scripts/build_windows.ps1 instead"
        echo "  powershell -File scripts/build_windows.ps1"
        exit 1
        ;;
    *)
        echo "✗ Unsupported platform: $OS"
        exit 1
        ;;
esac
