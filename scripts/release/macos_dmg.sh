#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# macos_dmg.sh — Create a .dmg installer for macOS
#
# Prerequisites:
#   - A signed .app bundle from build_macos.sh
#   - create-dmg (brew install create-dmg) OR hdiutil fallback
#
# Usage:
#   bash scripts/release/macos_dmg.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — macOS DMG Installer                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Locate the .app ─────────────────────────────────────────────────────
APP_DIR="$FLUTTER_DIR/build/macos/Build/Products/Release"
APP_NAME="$(ls "$APP_DIR" 2>/dev/null | grep '\.app$' | head -1 || true)"

if [ -z "$APP_NAME" ]; then
    echo "✗ No .app found in $APP_DIR"
    echo "  Run: bash scripts/build/build_macos.sh first"
    exit 1
fi

APP_PATH="$APP_DIR/$APP_NAME"
DMG_NAME="Studiomc"
VERSION="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")"
OUTPUT_DIR="$PROJECT_ROOT/dist"
DMG_PATH="$OUTPUT_DIR/${DMG_NAME}-${VERSION}-macOS.dmg"

mkdir -p "$OUTPUT_DIR"

echo "  App:     $APP_PATH"
echo "  Version: $VERSION"
echo "  Output:  $DMG_PATH"
echo ""

# ── Create DMG ──────────────────────────────────────────────────────────

# Prefer create-dmg if available (nicer UI, background image support)
if command -v create-dmg &>/dev/null; then
    echo "→ Using create-dmg…"

    # Remove previous DMG if it exists (create-dmg won't overwrite)
    rm -f "$DMG_PATH"

    create-dmg \
        --volname "$DMG_NAME" \
        --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
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
    echo "→ Using hdiutil (install create-dmg for a nicer DMG)…"

    STAGING="$OUTPUT_DIR/_dmg_staging"
    rm -rf "$STAGING"
    mkdir -p "$STAGING"
    cp -R "$APP_PATH" "$STAGING/"

    # Add convenience symlink to /Applications
    ln -s /Applications "$STAGING/Applications"

    # Copy license if it exists
    if [ -f "$PROJECT_ROOT/LICENSE" ]; then
        cp "$PROJECT_ROOT/LICENSE" "$STAGING/LICENSE.txt"
    fi

    rm -f "$DMG_PATH"
    hdiutil create -volname "$DMG_NAME" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG_PATH"

    rm -rf "$STAGING"
fi

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
echo ""
echo "✓ DMG created!"
echo "  Path: $DMG_PATH"
echo "  Size: $DMG_SIZE"
