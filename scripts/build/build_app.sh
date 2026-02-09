#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_app.sh — Build the complete Studiomc application
#
# Steps:
#   1. Build the Python services bundle
#   2. Copy the bundle into the Flutter app's bundled-resources directory
#   3. Build the Flutter desktop app for the current platform
#
# Usage:
#   bash scripts/build/build_app.sh [--skip-services]
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"

SKIP_SERVICES=false
for arg in "$@"; do
    case $arg in
        --skip-services) SKIP_SERVICES=true ;;
    esac
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — Full Application Build                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Build Python services ────────────────────────────────────────────
if [ "$SKIP_SERVICES" = false ]; then
    echo "═══ Step 1/3: Building Python services bundle ═══"
    bash "$SCRIPT_DIR/build_services.sh"
    echo ""
else
    echo "═══ Step 1/3: Skipping services build (--skip-services) ═══"
    if [ ! -d "$SERVICES_DIR/dist/studiomc_services" ]; then
        echo "✗ Services bundle not found. Run without --skip-services first."
        exit 1
    fi
fi

# ── 2. Copy bundle into Flutter app resources ───────────────────────────
echo "═══ Step 2/3: Staging services bundle ═══"

BUNDLE_SRC="$SERVICES_DIR/dist/studiomc_services"

# Detect platform and set destination
case "$(uname -s)" in
    Darwin*)
        # macOS: Flutter build will pick up from a known staging directory.
        # The actual embedding into the .app bundle is handled by build_macos.sh.
        BUNDLE_DEST="$FLUTTER_DIR/build/_services_stage"
        ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        BUNDLE_DEST="$FLUTTER_DIR/build/_services_stage"
        ;;
    Linux*)
        BUNDLE_DEST="$FLUTTER_DIR/build/_services_stage"
        ;;
esac

echo "→ Copying services bundle to $BUNDLE_DEST"
rm -rf "$BUNDLE_DEST"
mkdir -p "$BUNDLE_DEST"
cp -R "$BUNDLE_SRC"/* "$BUNDLE_DEST/"
echo "✓ Services staged"

# ── 3. Build Flutter app ────────────────────────────────────────────────
echo ""
echo "═══ Step 3/3: Building Flutter desktop app ═══"
cd "$FLUTTER_DIR"

case "$(uname -s)" in
    Darwin*)
        flutter build macos --release
        echo "✓ Flutter macOS build complete"
        echo "  Output: $FLUTTER_DIR/build/macos/Build/Products/Release/"
        ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        flutter build windows --release
        echo "✓ Flutter Windows build complete"
        echo "  Output: $FLUTTER_DIR/build/windows/x64/runner/Release/"
        ;;
    Linux*)
        flutter build linux --release
        echo "✓ Flutter Linux build complete"
        echo "  Output: $FLUTTER_DIR/build/linux/x64/release/bundle/"
        ;;
esac

echo ""
echo "✓ Full application build complete!"
echo "  Use the platform-specific release script to create an installer."
