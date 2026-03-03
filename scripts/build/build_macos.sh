#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_macos.sh — macOS-specific build pipeline
#
# Steps:
#   1. Build Python services bundle
#   2. Build Flutter macOS app
#   3. Embed services bundle inside the .app/Contents/Resources/
#   4. Sign and notarize (placeholder for CI)
#
# The resulting .app is fully self-contained — no system Python required.
#
# Usage:
#   bash scripts/build/build_macos.sh [--skip-services] [--sign]
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"

SKIP_SERVICES=false
DO_SIGN=false

for arg in "$@"; do
    case $arg in
        --skip-services) SKIP_SERVICES=true ;;
        --sign) DO_SIGN=true ;;
    esac
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — macOS Build                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Preflight ────────────────────────────────────────────────────────────
if [ "$(uname -s)" != "Darwin" ]; then
    echo "✗ This script must be run on macOS."
    exit 1
fi

ARCH="$(uname -m)"
echo "  Platform: macOS $(sw_vers -productVersion) ($ARCH)"
echo ""

# ── 1. Build services ───────────────────────────────────────────────────
if [ "$SKIP_SERVICES" = false ]; then
    echo "═══ Step 1/4: Building Python services ═══"
    bash "$SCRIPT_DIR/build_services.sh"
    echo ""
else
    echo "═══ Step 1/4: Skipping services build ═══"
fi

BUNDLE_SRC="$SERVICES_DIR/dist/studiomc_services"
if [ ! -d "$BUNDLE_SRC" ]; then
    echo "✗ Services bundle not found at $BUNDLE_SRC"
    exit 1
fi

# ── 2. Build Flutter macOS app ──────────────────────────────────────────
echo "═══ Step 2/4: Building Flutter macOS app ═══"
cd "$FLUTTER_DIR"
flutter build macos --release
echo "✓ Flutter build complete"
echo ""

# ── 3. Embed services into .app bundle ──────────────────────────────────
echo "═══ Step 3/4: Embedding services bundle ═══"

# Locate the .app — Flutter outputs to build/macos/Build/Products/Release/
APP_DIR="$FLUTTER_DIR/build/macos/Build/Products/Release"
APP_NAME="$(ls "$APP_DIR" | grep '\.app$' | head -1)"

if [ -z "$APP_NAME" ]; then
    echo "✗ Could not find .app in $APP_DIR"
    exit 1
fi

APP_PATH="$APP_DIR/$APP_NAME"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
SERVICES_DEST="$RESOURCES_DIR/studiomc_services"

echo "  App:      $APP_PATH"
echo "  Target:   $SERVICES_DEST"

rm -rf "$SERVICES_DEST"
mkdir -p "$SERVICES_DEST"
cp -R "$BUNDLE_SRC"/* "$SERVICES_DEST/"

# Ensure the main executable is, in fact, executable
chmod +x "$SERVICES_DEST/studiomc_services"

BUNDLE_SIZE=$(du -sh "$SERVICES_DEST" | cut -f1)
echo "✓ Services embedded ($BUNDLE_SIZE)"
echo ""

# ── 4. Code signing & notarization ──────────────────────────────────────
echo "═══ Step 4/4: Code signing ═══"

if [ "$DO_SIGN" = true ]; then
    # These environment variables must be set in CI or locally:
    #   APPLE_SIGNING_IDENTITY  — e.g. "Developer ID Application: ..."
    #   APPLE_TEAM_ID
    #   APPLE_ID
    #   APPLE_APP_PASSWORD      — app-specific password for notarytool
    IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
    if [ -z "$IDENTITY" ]; then
        echo "✗ APPLE_SIGNING_IDENTITY not set"
        exit 1
    fi

    echo "→ Signing with identity: $IDENTITY"

    # Sign all embedded binaries first (inside-out)
    find "$SERVICES_DEST" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
        -exec codesign --force --sign "$IDENTITY" --options runtime --timestamp {} \;

    # Sign the main app
    codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp "$APP_PATH"
    echo "✓ Code signed"

    # Notarize — notarytool requires a zip/dmg/pkg, not a bare .app
    echo "→ Creating zip for notarization…"
    NOTARIZE_ZIP="$APP_DIR/Studiomc-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    echo "→ Submitting for notarization…"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "${APPLE_ID}" \
        --team-id "${APPLE_TEAM_ID}" \
        --password "${APPLE_APP_PASSWORD}" \
        --wait

    rm -f "$NOTARIZE_ZIP"
    xcrun stapler staple "$APP_PATH"
    echo "✓ Notarization complete"
else
    echo "⊘ Skipping (pass --sign to enable)"
    echo "  For local testing, you can ad-hoc sign:"
    echo "    codesign --force --deep --sign - \"$APP_PATH\""
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ macOS build complete                             ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  App:   $APP_PATH"
echo "║  Size:  $(du -sh "$APP_PATH" | cut -f1)"
echo "╚══════════════════════════════════════════════════════╝"
