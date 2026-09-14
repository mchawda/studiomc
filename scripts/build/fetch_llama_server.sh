#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# fetch_llama_server.sh — Download a precompiled llama-server binary
#
# Pulls the right release asset from ggml-org/llama.cpp for the current
# host platform and drops the extracted ``llama-server`` binary (plus its
# shared libraries) into ``services/bin/`` so the dev checkout, the
# PyInstaller spec (which ships ``bin/`` as data inside the frozen
# bundle) and every platform build pick it up automatically.
#
# Upstream release scheme (2026):
#   * Build tags ``bNNNNN`` are pre-releases that carry the binaries:
#       llama-bNNNNN-bin-macos-arm64.tar.gz
#       llama-bNNNNN-bin-macos-x64.tar.gz
#       llama-bNNNNN-bin-ubuntu-x64.tar.gz
#       llama-bNNNNN-bin-ubuntu-arm64.tar.gz
#       llama-bNNNNN-bin-win-cpu-x64.zip
#   * Semver tags (``v0.4.0``) are the "latest" release but ship only a
#     ``nightly-tag.txt`` pointing at the build tag they correspond to.
#
# We therefore PIN a build tag by default (reproducible releases) and let
# ``LLAMA_CPP_VERSION`` override it. ``LLAMA_CPP_VERSION=latest`` resolves
# the build tag behind the newest semver release.
#
# Usage:
#   bash scripts/build/fetch_llama_server.sh
#   LLAMA_CPP_VERSION=b10951 bash scripts/build/fetch_llama_server.sh
#   LLAMA_CPP_VERSION=latest bash scripts/build/fetch_llama_server.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
BIN_DIR="$SERVICES_DIR/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO="ggml-org/llama.cpp"
# Pinned build tag. Bump deliberately; every bump must pass
# ``make smoke-fresh-install`` on all platforms.
DEFAULT_VERSION="b10809"
VERSION="${LLAMA_CPP_VERSION:-$DEFAULT_VERSION}"

# ── 1. Resolve platform ─────────────────────────────────────────────────

UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"

case "$UNAME_S/$UNAME_M" in
    Darwin/arm64)   ASSET_SUFFIX="bin-macos-arm64.tar.gz" ;;
    Darwin/x86_64)  ASSET_SUFFIX="bin-macos-x64.tar.gz" ;;
    Linux/x86_64)   ASSET_SUFFIX="bin-ubuntu-x64.tar.gz" ;;
    Linux/aarch64)  ASSET_SUFFIX="bin-ubuntu-arm64.tar.gz" ;;
    MINGW*/*|MSYS*/*|CYGWIN*/*)
                    ASSET_SUFFIX="bin-win-cpu-x64.zip" ;;
    *) echo "✗ Unsupported platform: $UNAME_S/$UNAME_M" ; exit 1 ;;
esac

BINARY_NAME="llama-server"
case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) BINARY_NAME="llama-server.exe" ;;
esac

echo "Platform: $UNAME_S/$UNAME_M  →  asset '*-$ASSET_SUFFIX'"

# ── 2. Skip if already installed at the requested version ──────────────

if [ "$VERSION" != "latest" ] \
   && [ -x "$BIN_DIR/$BINARY_NAME" ] \
   && [ -f "$BIN_DIR/VERSION" ] \
   && [ "$(cat "$BIN_DIR/VERSION")" = "$VERSION" ]; then
    echo "✓ $BINARY_NAME $VERSION already present in $BIN_DIR (skip)"
    exit 0
fi

# ── 3. Resolve release tag ──────────────────────────────────────────────

api_get() {
    # GitHub API with optional token (CI) to avoid rate limits. A stale or
    # invalid token must not break the build, so fall back to anonymous.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        if curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$1" 2>/dev/null; then
            return 0
        fi
        echo "  (GITHUB_TOKEN rejected by api.github.com; retrying anonymously)" >&2
    fi
    curl -fsSL "$1"
}

if [ "$VERSION" = "latest" ]; then
    echo "→ Resolving build tag behind the latest stable release of $REPO …"
    LATEST_JSON="$(api_get "https://api.github.com/repos/$REPO/releases/latest")"
    LATEST_TAG="$(printf '%s' "$LATEST_JSON" | grep -E '"tag_name"' | head -1 | cut -d'"' -f4)"
    NIGHTLY_URL="$(printf '%s' "$LATEST_JSON" \
        | grep '"browser_download_url"' | grep 'nightly-tag.txt' | head -1 | cut -d'"' -f4 || true)"
    if [ -n "$NIGHTLY_URL" ]; then
        VERSION="$(curl -fsSL "$NIGHTLY_URL" | tr -d '[:space:]')"
        echo "  $LATEST_TAG → build $VERSION"
    else
        VERSION="$LATEST_TAG"
    fi
    if [ -z "$VERSION" ]; then
        echo "✗ Could not determine a release tag" >&2
        exit 1
    fi
fi
echo "Release: $VERSION"

# ── 4. Pick the matching asset URL ──────────────────────────────────────

API_URL="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
ASSET_URL="$(api_get "$API_URL" \
    | grep '"browser_download_url"' \
    | grep -E "llama-[^\"]*-$ASSET_SUFFIX\"" \
    | head -1 | cut -d'"' -f4 || true)"

if [ -z "$ASSET_URL" ]; then
    echo "✗ No asset matching '*-$ASSET_SUFFIX' in release $VERSION" >&2
    echo "  Browse $API_URL to inspect available assets." >&2
    exit 1
fi

echo "Asset: $ASSET_URL"

# ── 5. Download + extract ───────────────────────────────────────────────

ARCHIVE="$TMP_DIR/llama-archive"
echo "→ Downloading…"
curl -fsSL "$ASSET_URL" -o "$ARCHIVE"

echo "→ Extracting…"
mkdir -p "$TMP_DIR/extracted"
case "$ASSET_URL" in
    *.tar.gz|*.tgz) tar -xzf "$ARCHIVE" -C "$TMP_DIR/extracted" ;;
    *.zip)
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$ARCHIVE" -d "$TMP_DIR/extracted"
        else
            # Git Bash on the Windows runners has no unzip; Python does.
            python -m zipfile -e "$ARCHIVE" "$TMP_DIR/extracted"
        fi
        ;;
    *) echo "✗ Unknown archive format: $ASSET_URL" >&2 ; exit 1 ;;
esac

FOUND_BIN="$(find "$TMP_DIR/extracted" -type f -name "$BINARY_NAME" | head -1 || true)"
if [ -z "$FOUND_BIN" ]; then
    echo "✗ '$BINARY_NAME' not found in archive" >&2
    find "$TMP_DIR/extracted" -type f -name 'llama*' >&2 || true
    exit 1
fi

# ── 6. Install into services/bin/ ───────────────────────────────────────

rm -rf "$BIN_DIR"
mkdir -p "$BIN_DIR"

SRC_DIR="$(dirname "$FOUND_BIN")"
echo "→ Installing into $BIN_DIR …"
cp "$FOUND_BIN" "$BIN_DIR/$BINARY_NAME"
chmod +x "$BIN_DIR/$BINARY_NAME"

# Shared libraries live next to the binary (macOS/Windows) or in a
# sibling ``lib/`` directory (Linux tarballs). llama-server is linked with
# an ``@rpath``/``$ORIGIN`` that expects them beside the executable.
shopt -s nullglob
for lib_dir in "$SRC_DIR" "$SRC_DIR/../lib" "$TMP_DIR/extracted/lib" "$TMP_DIR/extracted/build/bin"; do
    [ -d "$lib_dir" ] || continue
    for f in \
        "$lib_dir"/lib*.dylib \
        "$lib_dir"/lib*.so \
        "$lib_dir"/lib*.so.* \
        "$lib_dir"/*.dll \
        "$lib_dir"/ggml-metal*.metal \
        "$lib_dir"/*.metallib
    do
        cp -f "$f" "$BIN_DIR/" 2>/dev/null || true
    done
done
shopt -u nullglob

# macOS tarballs ship three copies of every library (libfoo.dylib,
# libfoo.0.dylib, libfoo.0.23.0.dylib) plus per-tool ``*-impl`` dylibs for
# llama-cli, llama-bench, etc. ``llama-server`` only links the ``.0``
# soname (see ``otool -L``), so prune the rest to keep the bundle small.
if [ "$UNAME_S" = "Darwin" ]; then
    for f in "$BIN_DIR"/*.dylib; do
        base="$(basename "$f")"
        if [ "$base" = "libllama-server-impl.dylib" ]; then
            continue
        fi
        # Keep exactly the soname form ``lib<name>.<major>.dylib``.
        if [[ "$base" =~ ^lib[^.]+\.[0-9]+\.dylib$ ]]; then
            continue
        fi
        rm -f "$f"
    done
fi

# Stamp the version so the runtime can show it in the UI and this script
# can skip re-downloading.
echo "$VERSION" > "$BIN_DIR/VERSION"

# ── 7. Verify ───────────────────────────────────────────────────────────

if "$BIN_DIR/$BINARY_NAME" --version >/dev/null 2>&1 \
   || "$BIN_DIR/$BINARY_NAME" --help >/dev/null 2>&1; then
    REPORTED="$("$BIN_DIR/$BINARY_NAME" --version 2>&1 | head -1 || true)"
    echo "✓ Installed $BINARY_NAME ($VERSION) → $BIN_DIR"
    [ -n "$REPORTED" ] && echo "  $REPORTED"
else
    echo "✗ $BINARY_NAME installed but failed to execute (missing shared libraries?)" >&2
    ls -la "$BIN_DIR" >&2
    exit 1
fi
