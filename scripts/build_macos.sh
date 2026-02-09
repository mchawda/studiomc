#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_macos.sh — Full macOS production build pipeline
#
# Steps:
#   1. Bundle Python services via PyInstaller (scripts/bundle_python.sh)
#   2. Build Flutter macOS app (flutter build macos --release)
#   3. Copy bundled Python into the .app/Contents/Resources/
#   4. Ad-hoc or Developer ID code sign
#   5. Create a .dmg installer
#
# The resulting .app is fully self-contained — NO system Python required.
# Users never see Python, pip, or a terminal.
#
# Usage:
#   bash scripts/build_macos.sh [options]
#
# Options:
#   --skip-services   Skip the Python bundling step (reuse previous bundle)
#   --skip-flutter    Skip the Flutter build step (reuse previous build)
#   --sign            Sign with Developer ID (requires APPLE_SIGNING_IDENTITY)
#   --dmg             Create a .dmg installer after building
#   --no-dmg          Skip DMG creation (default unless --dmg passed)
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"

SKIP_SERVICES=false
SKIP_FLUTTER=false
DO_SIGN=false
DO_DMG=false

for arg in "$@"; do
    case $arg in
        --skip-services) SKIP_SERVICES=true ;;
        --skip-flutter)  SKIP_FLUTTER=true ;;
        --sign)          DO_SIGN=true ;;
        --dmg)           DO_DMG=true ;;
        --no-dmg)        DO_DMG=false ;;
        -h|--help)
            echo "Usage: bash scripts/build_macos.sh [--skip-services] [--skip-flutter] [--sign] [--dmg]"
            exit 0
            ;;
    esac
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — macOS Production Build                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Preflight ─────────────────────────────────────────────────────────────

if [ "$(uname -s)" != "Darwin" ]; then
    echo "✗ This script must be run on macOS."
    exit 1
fi

ARCH="$(uname -m)"
echo "  Platform:  macOS $(sw_vers -productVersion) ($ARCH)"
echo "  Flutter:   $(flutter --version 2>&1 | head -1)"
echo "  Options:   services=$([ "$SKIP_SERVICES" = true ] && echo "skip" || echo "build")" \
     "flutter=$([ "$SKIP_FLUTTER" = true ] && echo "skip" || echo "build")" \
     "sign=$([ "$DO_SIGN" = true ] && echo "yes" || echo "no")" \
     "dmg=$([ "$DO_DMG" = true ] && echo "yes" || echo "no")"
echo ""

TOTAL_STEPS=5
STEP=0

# ── Step 1: Bundle Python services ────────────────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Python services bundle ═══"

if [ "$SKIP_SERVICES" = false ]; then
    bash "$SCRIPT_DIR/bundle_python.sh" --clean
    echo ""
else
    echo "⊘ Skipping (--skip-services)"
fi

BUNDLE_SRC="$SERVICES_DIR/dist/studiomc_services"
if [ ! -d "$BUNDLE_SRC" ]; then
    echo "✗ Services bundle not found at $BUNDLE_SRC"
    echo "  Run without --skip-services to build it."
    exit 1
fi
echo "✓ Services bundle ready ($(du -sh "$BUNDLE_SRC" | cut -f1))"
echo ""

# ── Step 2: Build Flutter macOS app ──────────────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Flutter macOS release build ═══"

if [ "$SKIP_FLUTTER" = false ]; then
    cd "$FLUTTER_DIR"
    flutter build macos --release
    echo "✓ Flutter build complete"
else
    echo "⊘ Skipping (--skip-flutter)"
fi
echo ""

# ── Step 3: Embed services into .app bundle ──────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Embed Python bundle into .app ═══"

# Locate the .app — Flutter outputs to build/macos/Build/Products/Release/
APP_DIR="$FLUTTER_DIR/build/macos/Build/Products/Release"
APP_NAME="$(ls "$APP_DIR" 2>/dev/null | grep '\.app$' | head -1 || true)"

if [ -z "$APP_NAME" ]; then
    echo "✗ Could not find .app in $APP_DIR"
    echo "  Run without --skip-flutter to build the Flutter app."
    exit 1
fi

APP_PATH="$APP_DIR/$APP_NAME"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
SERVICES_DEST="$RESOURCES_DIR/studiomc_services"

echo "  App:    $APP_PATH"
echo "  Embed:  $SERVICES_DEST"

# Remove old bundle and copy fresh one
rm -rf "$SERVICES_DEST"
mkdir -p "$SERVICES_DEST"
cp -R "$BUNDLE_SRC"/* "$SERVICES_DEST/"

# Ensure the main executable has execute permission
chmod +x "$SERVICES_DEST/studiomc_services"

EMBED_SIZE="$(du -sh "$SERVICES_DEST" | cut -f1)"
echo "✓ Services embedded ($EMBED_SIZE)"
echo ""

# ── Step 4: Code signing ─────────────────────────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: Code signing ═══"

if [ "$DO_SIGN" = true ]; then
    # Required env vars for Developer ID signing:
    #   APPLE_SIGNING_IDENTITY  — e.g. "Developer ID Application: Your Name (TEAMID)"
    #   APPLE_TEAM_ID           — for notarization
    #   APPLE_ID                — Apple ID email for notarization
    #   APPLE_APP_PASSWORD      — app-specific password for notarytool
    IDENTITY="${APPLE_SIGNING_IDENTITY:-}"
    if [ -z "$IDENTITY" ]; then
        echo "✗ APPLE_SIGNING_IDENTITY not set."
        echo "  Export it before running with --sign:"
        echo '    export APPLE_SIGNING_IDENTITY="Developer ID Application: ..."'
        exit 1
    fi

    echo "→ Signing with: $IDENTITY"

    # Sign embedded binaries first (inside-out signing order)
    echo "→ Signing embedded Python binaries…"
    find "$SERVICES_DEST" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) \
        -exec codesign --force --sign "$IDENTITY" --options runtime --timestamp {} \;

    # Sign all frameworks in the .app
    echo "→ Signing frameworks…"
    find "$APP_PATH/Contents/Frameworks" -name "*.framework" -type d \
        -exec codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp {} \;

    # Sign the main app bundle
    echo "→ Signing app bundle…"
    codesign --force --deep --sign "$IDENTITY" --options runtime --timestamp "$APP_PATH"
    echo "✓ Code signed"

    # Notarize if credentials are available
    if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
        echo ""
        echo "→ Submitting for notarization (this may take several minutes)…"
        xcrun notarytool submit "$APP_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --wait

        xcrun stapler staple "$APP_PATH"
        echo "✓ Notarization complete"
    else
        echo "  ⚠ Notarization skipped (APPLE_ID / APPLE_TEAM_ID / APPLE_APP_PASSWORD not all set)"
    fi
else
    echo "⊘ Skipping Developer ID signing (pass --sign to enable)"
    echo ""
    echo "  For local testing you can ad-hoc sign:"
    echo "    codesign --force --deep --sign - \"$APP_PATH\""
    echo ""
    echo "  Ad-hoc signing now…"
    codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true
    echo "✓ Ad-hoc signed (for local testing only)"
fi
echo ""

# ── Step 5: Create DMG installer ─────────────────────────────────────────

STEP=$((STEP + 1))
echo "═══ Step $STEP/$TOTAL_STEPS: DMG installer ═══"

if [ "$DO_DMG" = true ]; then
    VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")"
    DMG_NAME="Studiomc"
    OUTPUT_DIR="$PROJECT_ROOT/dist"
    DMG_PATH="$OUTPUT_DIR/${DMG_NAME}-${VERSION}-macOS-${ARCH}.dmg"

    mkdir -p "$OUTPUT_DIR"
    rm -f "$DMG_PATH"

    echo "  Version: $VERSION"
    echo "  Output:  $DMG_PATH"
    echo ""

    if command -v create-dmg &>/dev/null; then
        echo "→ Using create-dmg…"
        create-dmg \
            --volname "$DMG_NAME" \
            --window-pos 200 120 \
            --window-size 660 400 \
            --icon-size 100 \
            --icon "$APP_NAME" 180 190 \
            --hide-extension "$APP_NAME" \
            --app-drop-link 480 190 \
            --no-internet-enable \
            "$DMG_PATH" \
            "$APP_PATH"
    else
        echo "→ Using hdiutil (install create-dmg for a prettier DMG)…"
        STAGING="$OUTPUT_DIR/_dmg_staging"
        rm -rf "$STAGING"
        mkdir -p "$STAGING"
        cp -R "$APP_PATH" "$STAGING/"
        ln -s /Applications "$STAGING/Applications"

        [ -f "$PROJECT_ROOT/LICENSE" ] && cp "$PROJECT_ROOT/LICENSE" "$STAGING/LICENSE.txt"

        hdiutil create -volname "$DMG_NAME" \
            -srcfolder "$STAGING" \
            -ov -format UDZO \
            "$DMG_PATH"

        rm -rf "$STAGING"
    fi

    DMG_SIZE="$(du -sh "$DMG_PATH" | cut -f1)"
    echo "✓ DMG created ($DMG_SIZE)"
else
    echo "⊘ Skipping (pass --dmg to create installer)"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────

APP_SIZE="$(du -sh "$APP_PATH" | cut -f1)"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ macOS production build complete                  ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  App:    $APP_PATH"
echo "║  Size:   $APP_SIZE"
if [ "$DO_DMG" = true ] && [ -f "$DMG_PATH" ]; then
echo "║  DMG:    $DMG_PATH"
fi
echo "║  Arch:   $ARCH"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "To test locally:"
echo "  open \"$APP_PATH\""
