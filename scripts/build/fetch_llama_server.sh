#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# fetch_llama_server.sh — Download a precompiled llama-server binary
#
# Pulls the right release asset from ggerganov/llama.cpp for the current
# host platform and drops the extracted ``llama-server`` binary into
# ``services/bin/`` so the dev checkout, PyInstaller spec, and macOS .app
# embed step (build_macos.sh) all pick it up automatically.
#
# Set $LLAMA_CPP_VERSION to pin a specific release (e.g. b4400). Defaults
# to the latest published release.
#
# Usage:
#   bash scripts/build/fetch_llama_server.sh
#   LLAMA_CPP_VERSION=b4400 bash scripts/build/fetch_llama_server.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
BIN_DIR="$SERVICES_DIR/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="ggerganov/llama.cpp"
VERSION="${LLAMA_CPP_VERSION:-}"

# ── 1. Resolve platform ─────────────────────────────────────────────────

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"

# Upstream publishes ``llama-<tag>-bin-<platform>.(zip|tar.gz)``; the
# archive type changed from zip to tar.gz for macOS/Linux in 2026, so match
# on the platform stem and accept either extension.
case "$UNAME_S/$UNAME_M" in
    Darwin/arm64)   ASSET_PATTERN="bin-macos-arm64" ;;
    Darwin/x86_64)  ASSET_PATTERN="bin-macos-x64" ;;
    Linux/x86_64)   ASSET_PATTERN="bin-ubuntu-x64" ;;
    Linux/aarch64)  ASSET_PATTERN="bin-ubuntu-arm64" ;;
    MINGW*/*|MSYS*/*|CYGWIN*/*)
                    ASSET_PATTERN="bin-win-cpu-x64" ;;
    *) echo "✗ Unsupported platform: $UNAME_S/$UNAME_M" ; exit 1 ;;
esac

echo "Platform: $UNAME_S/$UNAME_M  →  asset pattern '*$ASSET_PATTERN.(zip|tar.gz)'"

# ── 2. Resolve release tag ──────────────────────────────────────────────

if [ -z "$VERSION" ]; then
    # ``/releases/latest`` points at the semver release (e.g. v0.4.0) which
    # carries no binaries; the prebuilt binaries are attached to the
    # ``b<build>`` pre-releases, so take the newest of those instead.
    echo "→ Querying latest binary build of $REPO …"
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=20" \
        | grep -E '"tag_name": *"b[0-9]+"' | head -1 | cut -d'"' -f4)"
    if [ -z "$VERSION" ]; then
        echo "✗ Could not determine latest release tag" >&2
        exit 1
    fi
fi
echo "Release: $VERSION"

# ── 3. Pick the matching asset URL ──────────────────────────────────────

API_URL="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
ASSET_URL="$(curl -fsSL "$API_URL" \
    | grep '"browser_download_url"' \
    | grep -E "$ASSET_PATTERN\.(zip|tar\.gz)\"" \
    | head -1 | cut -d'"' -f4 || true)"

if [ -z "$ASSET_URL" ]; then
    echo "✗ No asset matching '*$ASSET_PATTERN.(zip|tar.gz)' in release $VERSION" >&2
    echo "  Browse $API_URL to inspect available assets." >&2
    exit 1
fi

echo "Asset: $ASSET_URL"

# ── 4. Download + extract ───────────────────────────────────────────────

case "$ASSET_URL" in
    *.tar.gz) ARCHIVE="$TMP_DIR/llama.tar.gz" ;;
    *)        ARCHIVE="$TMP_DIR/llama.zip" ;;
esac
echo "→ Downloading…"
curl -fsSL "$ASSET_URL" -o "$ARCHIVE"

echo "→ Extracting…"
mkdir -p "$TMP_DIR/extracted"
case "$ARCHIVE" in
    *.tar.gz) tar -xzf "$ARCHIVE" -C "$TMP_DIR/extracted" ;;
    *)        unzip -q "$ARCHIVE" -d "$TMP_DIR/extracted" ;;
esac

# Locate the binary inside the archive (release layout varies a bit)
BINARY_NAME="llama-server"
case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) BINARY_NAME="llama-server.exe" ;;
esac

FOUND_BIN="$(find "$TMP_DIR/extracted" -type f -name "$BINARY_NAME" | head -1 || true)"
if [ -z "$FOUND_BIN" ]; then
    echo "✗ '$BINARY_NAME' not found in archive" >&2
    find "$TMP_DIR/extracted" -type f -name 'llama*' >&2 || true
    exit 1
fi

# ── 5. Install into services/bin/ ───────────────────────────────────────

mkdir -p "$BIN_DIR"

# Copy the binary plus any sibling shared libraries it needs
SRC_DIR="$(dirname "$FOUND_BIN")"
echo "→ Installing into $BIN_DIR …"
cp "$FOUND_BIN" "$BIN_DIR/$BINARY_NAME"
chmod +x "$BIN_DIR/$BINARY_NAME"

# Copy adjacent libs (libllama.*, libggml.*, ggml-metal.metal, etc.)
shopt -s nullglob
for f in \
    "$SRC_DIR"/lib*.dylib \
    "$SRC_DIR"/lib*.so \
    "$SRC_DIR"/lib*.so.* \
    "$SRC_DIR"/*.dll \
    "$SRC_DIR"/ggml-metal*.metal \
    "$SRC_DIR"/*.metallib
do
    cp "$f" "$BIN_DIR/" 2>/dev/null || true
done

# Stamp the version so the runtime can show it in the UI
echo "$VERSION" > "$BIN_DIR/VERSION"

# ── 6. Verify ───────────────────────────────────────────────────────────

if "$BIN_DIR/$BINARY_NAME" --version >/dev/null 2>&1 \
   || "$BIN_DIR/$BINARY_NAME" --help >/dev/null 2>&1; then
    REPORTED="$("$BIN_DIR/$BINARY_NAME" --version 2>&1 | head -1 || true)"
    echo "✓ Installed $BINARY_NAME ($VERSION) → $BIN_DIR"
    [ -n "$REPORTED" ] && echo "  $REPORTED"
else
    echo "⚠ $BINARY_NAME installed but failed --version probe (continuing)"
fi
