#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# linux_appimage.sh — Build an AppImage for Linux distribution
#
# Prerequisites:
#   - Flutter Linux release build at studiomc_app/build/linux/x64/release/bundle/
#   - Services bundle at services/dist/studiomc_services/
#   - appimagetool in PATH (https://github.com/AppImage/appimagetool)
#
# Usage:
#   bash scripts/release/linux_appimage.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"
SERVICES_DIR="$PROJECT_ROOT/services"

APP_NAME="Studiomc"
VERSION="1.0.0"
OUTPUT_DIR="$PROJECT_ROOT/dist"
APPDIR="$OUTPUT_DIR/${APP_NAME}.AppDir"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — Linux AppImage Builder                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Preflight checks ───────────────────────────────────────────────────
FLUTTER_BUNDLE="$FLUTTER_DIR/build/linux/x64/release/bundle"
SERVICES_BUNDLE="$SERVICES_DIR/dist/studiomc_services"

if [ ! -d "$FLUTTER_BUNDLE" ]; then
    echo "✗ Flutter Linux build not found at $FLUTTER_BUNDLE"
    echo "  Run: cd studiomc_app && flutter build linux --release"
    exit 1
fi

if [ ! -d "$SERVICES_BUNDLE" ]; then
    echo "✗ Services bundle not found at $SERVICES_BUNDLE"
    echo "  Run: bash scripts/build/build_services.sh"
    exit 1
fi

if ! command -v appimagetool &>/dev/null; then
    echo "✗ appimagetool not found in PATH"
    echo "  Download from: https://github.com/AppImage/appimagetool/releases"
    exit 1
fi

# ── Build AppDir structure ──────────────────────────────────────────────
echo "→ Creating AppDir…"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"

# Copy Flutter bundle
cp -R "$FLUTTER_BUNDLE"/* "$APPDIR/usr/bin/"

# Copy services bundle alongside the runner
cp -R "$SERVICES_BUNDLE" "$APPDIR/usr/bin/studiomc_services"
chmod +x "$APPDIR/usr/bin/studiomc_services/studiomc_services"

# ── Desktop file ────────────────────────────────────────────────────────
cat > "$APPDIR/studiomc.desktop" << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Studiomc
Comment=Local AI Desktop App
Exec=studiomc_app
Icon=studiomc
Categories=Development;Science;
Terminal=false
StartupWMClass=studiomc_app
DESKTOP

# ── AppRun script ───────────────────────────────────────────────────────
cat > "$APPDIR/AppRun" << 'APPRUN'
#!/bin/bash
# AppRun — entry point for the AppImage
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="${HERE}/usr/lib:${HERE}/usr/bin/lib:${LD_LIBRARY_PATH:-}"
exec "${HERE}/usr/bin/studiomc_app" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

# ── Icon ────────────────────────────────────────────────────────────────
# Use the app icon if available, otherwise create a placeholder
ICON_SRC="$FLUTTER_DIR/linux/flutter/ephemeral/.plugin_symlinks"
if [ -f "$FLUTTER_DIR/assets/images/icon.png" ]; then
    cp "$FLUTTER_DIR/assets/images/icon.png" "$APPDIR/studiomc.png"
else
    # Create a minimal 1x1 PNG as placeholder (avoids appimagetool warnings)
    echo "⚠ No icon found — using placeholder. Add assets/images/icon.png."
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' > "$APPDIR/studiomc.png"
fi

# ── Build AppImage ──────────────────────────────────────────────────────
echo "→ Building AppImage…"
mkdir -p "$OUTPUT_DIR"

APPIMAGE_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}-x86_64.AppImage"
ARCH=x86_64 appimagetool "$APPDIR" "$APPIMAGE_PATH"

rm -rf "$APPDIR"

APPIMAGE_SIZE=$(du -sh "$APPIMAGE_PATH" | cut -f1)
echo ""
echo "✓ AppImage created!"
echo "  Path: $APPIMAGE_PATH"
echo "  Size: $APPIMAGE_SIZE"
