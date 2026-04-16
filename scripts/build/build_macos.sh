#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_macos.sh — Build the macOS .app with embedded Python services
#
# Steps:
#   1. Bundle Python services (unless --skip-services)
#   2. Build Flutter macOS app (flutter build macos --release)
#   3. Embed the services bundle inside the .app
#
# The resulting .app is self-contained — no system Python needed.
# Code signing and DMG creation are handled separately by CI or release scripts.
#
# Called by:
#   - release.yml (CI) with --skip-services (services built in prior step)
#   - Makefile (make build-macos)
#   - scripts/build_macos.sh (wrapper)
#   - scripts/build-macos.sh (convenience wrapper)
#
# Usage:
#   bash scripts/build/build_macos.sh [--skip-services] [--skip-flutter] [--clean]
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

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — macOS Production Build                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Platform:  $(uname -m) / macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
echo "  Flutter:   $(flutter --version 2>/dev/null | head -1 || echo 'not found')"
echo ""

TOTAL_STEPS=3
STEP=0

# ── Step 1: Bundle Python services ──────────────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Bundle Python services ═══"

SERVICES_BUNDLE="$SERVICES_DIR/dist/studiomc_services"

if [ "$SKIP_SERVICES" = true ]; then
    echo "⊘ Skipping (--skip-services)"
    if [ ! -d "$SERVICES_BUNDLE" ]; then
        echo "✗ Services bundle not found at $SERVICES_BUNDLE"
        echo "  Build services first or remove --skip-services"
        exit 1
    fi
    echo "✓ Using existing bundle at $SERVICES_BUNDLE"
else
    CLEAN_ARG=""
    if [ "$CLEAN" = true ]; then CLEAN_ARG="--clean"; fi
    bash "$SCRIPT_DIR/build_services.sh" $CLEAN_ARG
fi
echo ""

# ── Step 2: Build Flutter macOS app ─────────────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Flutter macOS release build ═══"

if [ "$SKIP_FLUTTER" = true ]; then
    echo "⊘ Skipping (--skip-flutter)"
else
    if [ "$CLEAN" = true ]; then
        echo "→ Cleaning Flutter build…"
        cd "$FLUTTER_DIR" && flutter clean
    fi

    cd "$FLUTTER_DIR"
    flutter build macos --release
    echo "✓ Flutter build complete"
fi
echo ""

# ── Step 3: Embed services into .app bundle ─────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Embed services into .app ═══"

APP_DIR="$FLUTTER_DIR/build/macos/Build/Products/Release"
APP_NAME="$(ls "$APP_DIR" 2>/dev/null | grep '\.app$' | head -1 || true)"

if [ -z "$APP_NAME" ]; then
    echo "✗ No .app found in $APP_DIR"
    exit 1
fi

APP_PATH="$APP_DIR/$APP_NAME"
RESOURCES_DIR="$APP_PATH/Contents/Resources"

# Embed services bundle
SERVICES_DEST="$RESOURCES_DIR/studiomc_services"
if [ -d "$SERVICES_DEST" ]; then
    rm -rf "$SERVICES_DEST"
fi
cp -R "$SERVICES_BUNDLE" "$SERVICES_DEST"
chmod +x "$SERVICES_DEST/studiomc_services" 2>/dev/null || true
echo "✓ Services embedded into $APP_NAME"

# Embed llama-server binaries if present
LLAMA_BIN="$SERVICES_DIR/bin"
if [ -d "$LLAMA_BIN" ]; then
    BIN_DEST="$RESOURCES_DIR/bin"
    mkdir -p "$BIN_DEST"
    cp -R "$LLAMA_BIN"/* "$BIN_DEST/"
    find "$BIN_DEST" -type f -exec chmod +x {} \;
    echo "✓ llama-server binaries embedded"
fi

# ── Summary ──────────────────────────────────────────────────────────────

APP_SIZE="$(du -sh "$APP_PATH" | cut -f1)"
VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 'unknown')"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ macOS build complete                             ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  App:      $APP_PATH"
echo "║  Version:  $VERSION"
echo "║  Size:     $APP_SIZE"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  • Sign:  codesign --force --sign 'Developer ID Application' --options runtime --entitlements ... '$APP_PATH'"
echo "  • DMG:   bash scripts/release/macos_dmg.sh"
echo "  • Test:  open '$APP_PATH'"
