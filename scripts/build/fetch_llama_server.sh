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

case "$UNAME_S/$UNAME_M" in
    Darwin/arm64)   ASSET_PATTERN="macos-arm64.zip" ;;
    Darwin/x86_64)  ASSET_PATTERN="macos-x64.zip" ;;
    Linux/x86_64)   ASSET_PATTERN="ubuntu-x64.zip" ;;
    Linux/aarch64)  ASSET_PATTERN="ubuntu-arm64.zip" ;;
    MINGW*/*|MSYS*/*|CYGWIN*/*)
                    ASSET_PATTERN="win-avx2-x64.zip" ;;
    *) echo "✗ Unsupported platform: $UNAME_S/$UNAME_M" ; exit 1 ;;
esac

echo "Platform: $UNAME_S/$UNAME_M  →  asset pattern '*$ASSET_PATTERN'"

# ── 2. Resolve release tag ──────────────────────────────────────────────

if [ -z "$VERSION" ]; then
    echo "→ Querying latest release of $REPO …"
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -E '"tag_name"' | head -1 | cut -d'"' -f4)"
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
    | grep -E "$ASSET_PATTERN\"" \
    | head -1 | cut -d'"' -f4 || true)"

if [ -z "$ASSET_URL" ]; then
    echo "✗ No asset matching '*$ASSET_PATTERN' in release $VERSION" >&2
    echo "  Browse $API_URL to inspect available assets." >&2
    exit 1
fi

echo "Asset: $ASSET_URL"

# ── 4. Download + extract ───────────────────────────────────────────────

ARCHIVE="$TMP_DIR/llama.zip"
echo "→ Downloading…"
curl -fsSL "$ASSET_URL" -o "$ARCHIVE"

echo "→ Extracting…"
unzip -q "$ARCHIVE" -d "$TMP_DIR/extracted"

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
