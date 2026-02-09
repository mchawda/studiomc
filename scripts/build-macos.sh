#!/usr/bin/env bash
set -euo pipefail

# ─── Studiomc macOS Build Script ───────────────────────────────────
# Builds the Flutter app and packages it into a DMG for distribution.
#
# Usage:
#   ./scripts/build-macos.sh              # Build release DMG
#   ./scripts/build-macos.sh --skip-build # Package existing build into DMG
#
# Output: dist/Studiomc-<version>-macos.dmg
# ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_ROOT/studiomc_app"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="Studiomc"

# Read version from pubspec.yaml
VERSION=$(grep '^version:' "$APP_DIR/pubspec.yaml" | head -1 | awk '{print $2}' | cut -d'+' -f1)
DMG_NAME="${APP_NAME}-${VERSION}-macos.dmg"

SKIP_BUILD=false
if [[ "${1:-}" == "--skip-build" ]]; then
  SKIP_BUILD=true
fi

echo "══════════════════════════════════════════"
echo "  $APP_NAME macOS Build  v$VERSION"
echo "══════════════════════════════════════════"

# ── Step 1: Flutter build ──
if [[ "$SKIP_BUILD" == false ]]; then
  echo ""
  echo "► Building Flutter macOS release..."
  cd "$APP_DIR"
  flutter build macos --release
  echo "  ✓ Build complete"
fi

BUILD_APP="$APP_DIR/build/macos/Build/Products/Release/studiomc_app.app"
if [[ ! -d "$BUILD_APP" ]]; then
  echo "ERROR: Build artifact not found at $BUILD_APP"
  exit 1
fi

# ── Step 2: Create dist directory ──
mkdir -p "$DIST_DIR"

# ── Step 3: Create DMG ──
echo ""
echo "► Packaging DMG..."

STAGING_DIR=$(mktemp -d)
trap 'rm -rf "$STAGING_DIR"' EXIT

# Copy .app to staging
cp -R "$BUILD_APP" "$STAGING_DIR/${APP_NAME}.app"

# Create symlink to /Applications for drag-install
ln -s /Applications "$STAGING_DIR/Applications"

# Remove old DMG if exists
rm -f "$DIST_DIR/$DMG_NAME"

# Create DMG using hdiutil
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

echo ""
echo "══════════════════════════════════════════"
echo "  ✓ DMG ready: dist/$DMG_NAME"
echo "  Size: $(du -h "$DIST_DIR/$DMG_NAME" | cut -f1)"
echo "══════════════════════════════════════════"
echo ""
echo "To share: upload dist/$DMG_NAME to GitHub Releases"
echo "Your friend can install by:"
echo "  1. Download the DMG"
echo "  2. Open it and drag Studiomc to Applications"
echo "  3. Right-click the app → Open (first time only, bypasses Gatekeeper)"
echo "  4. Install Ollama from ollama.com if not already installed"
