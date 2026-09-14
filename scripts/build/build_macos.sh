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

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" != "arm64" ]; then
    echo "✗ Studiomc macOS product builds require Apple Silicon (arm64)." >&2
    echo "  This host is $HOST_ARCH. Intel Mac desktop builds are not shipped." >&2
    echo "  Use an Apple Silicon Mac, or build for Windows on a Windows host." >&2
    exit 1
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — macOS Production Build (Apple Silicon)  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Platform:  $HOST_ARCH / macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
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

# llama-server ships INSIDE the services bundle (_internal/bin, added as
# data by studiomc_services.spec) so every platform gets it the same way.
# Verify it made it into the .app rather than copying a second 24 MB copy.
if [ ! -f "$SERVICES_DEST/_internal/bin/llama-server" ]; then
    echo "✗ llama-server missing from $SERVICES_DEST/_internal/bin"
    echo "  Run: bash scripts/build/fetch_llama_server.sh && bash scripts/build/build_services.sh"
    exit 1
fi
chmod +x "$SERVICES_DEST/_internal/bin/llama-server"
echo "✓ llama-server sidecar present ($(cat "$SERVICES_DEST/_internal/bin/VERSION" 2>/dev/null || echo '?'))"

# Remove a stale copy left by older build scripts so signing/notarization
# does not have to cover two of everything.
rm -rf "$RESOURCES_DIR/bin"

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
echo "  • Smoke: python3 scripts/build/smoke_bundle.py --app '$APP_PATH'   (make smoke-fresh-install)"
echo "  • Sign:  codesign --force --sign 'Developer ID Application' --options runtime --entitlements ... '$APP_PATH'"
echo "  • DMG:   bash scripts/release/macos_dmg.sh"
echo "  • Test:  open '$APP_PATH'"
