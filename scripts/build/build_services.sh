#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_services.sh — Bundle Python services with PyInstaller
#
# Produces a self-contained directory at services/dist/studiomc_services/
# that includes a frozen Python interpreter and all pip dependencies.
# No system Python required to run the bundle.
#
# Called by:
#   - release.yml (CI)
#   - Makefile (make build-services)
#   - scripts/build_macos.sh (wrapper)
#
# Usage:
#   bash scripts/build/build_services.sh [--clean]
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
VENV_DIR="$SERVICES_DIR/.venv"

CLEAN=false
for arg in "$@"; do
    case $arg in
        --clean) CLEAN=true ;;
    esac
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — Build Services (PyInstaller)            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Activate venv ─────────────────────────────────────────────────────

if [ ! -d "$VENV_DIR" ]; then
    echo "✗ Virtual environment not found at $VENV_DIR"
    echo ""
    echo "  Set it up with:"
    echo "    cd services"
    echo "    python3 -m venv .venv"
    echo "    source .venv/bin/activate"
    echo '    pip install ".[inference]"'
    echo "    pip install pyinstaller"
    exit 1
fi

# Detect platform-appropriate activation
if [ -f "$VENV_DIR/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
elif [ -f "$VENV_DIR/Scripts/activate" ]; then
    # shellcheck disable=SC1091
    source "$VENV_DIR/Scripts/activate"
else
    echo "✗ Cannot find venv activate script"
    exit 1
fi

echo "✓ Activated venv: $(which python)"
echo "  Python version: $(python --version 2>&1)"

# ── 2. Ensure PyInstaller ────────────────────────────────────────────────

if ! python -m PyInstaller --version &>/dev/null; then
    echo "→ Installing PyInstaller…"
    pip install pyinstaller
fi
echo "✓ PyInstaller $(python -m PyInstaller --version 2>&1)"

# ── 3. Verify spec file ─────────────────────────────────────────────────

SPEC_FILE="$SERVICES_DIR/studiomc_services.spec"
if [ ! -f "$SPEC_FILE" ]; then
    echo "✗ PyInstaller spec not found at $SPEC_FILE"
    exit 1
fi
echo "✓ Spec file: $SPEC_FILE"
echo ""

# ── 4. Clean previous artifacts ─────────────────────────────────────────

DIST_DIR="$SERVICES_DIR/dist/studiomc_services"
BUILD_DIR="$SERVICES_DIR/build/studiomc_services"

if [ "$CLEAN" = true ] || [ -d "$DIST_DIR" ]; then
    echo "→ Cleaning previous build artifacts…"
    rm -rf "$DIST_DIR" "$BUILD_DIR"
    echo "✓ Clean"
fi

# ── 4b. Require the llama-server sidecar ────────────────────────────────
# Without it the Core bundle has no built-in inference engine and a fresh
# user (no Ollama) cannot chat at all. Fetch it if missing.

LLAMA_BIN_NAME="llama-server"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) LLAMA_BIN_NAME="llama-server.exe" ;;
esac
if [ ! -x "$SERVICES_DIR/bin/$LLAMA_BIN_NAME" ]; then
    echo "→ llama-server not found in services/bin — fetching…"
    bash "$SCRIPT_DIR/fetch_llama_server.sh"
fi
echo "✓ llama-server: $(cat "$SERVICES_DIR/bin/VERSION" 2>/dev/null || echo present)"

# ── 4c. Stamp build identity ────────────────────────────────────────────
# Shipped inside the bundle; the supervisor reports it from /health so the
# desktop app can tell a stale supervisor from its own.

APP_VERSION="$(grep -E '^version:' "$PROJECT_ROOT/studiomc_app/pubspec.yaml" | head -1 | sed -E 's/^version:[[:space:]]*//' | tr -d '\r')"
GIT_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$SERVICES_DIR/BUILD_INFO.json" <<EOF
{"version": "${APP_VERSION:-unknown}", "git_sha": "$GIT_SHA", "built_at": "$BUILT_AT"}
EOF
echo "✓ BUILD_INFO: version=${APP_VERSION:-unknown} sha=$GIT_SHA"

# ── 5. Run PyInstaller ──────────────────────────────────────────────────

echo "→ Running PyInstaller (this may take a few minutes)…"
echo ""

cd "$SERVICES_DIR"
python -m PyInstaller studiomc_services.spec --clean --noconfirm

echo ""

# ── 6. Verify the bundle ────────────────────────────────────────────────

if [ ! -d "$DIST_DIR" ]; then
    echo "✗ Build failed — output directory not found at $DIST_DIR"
    exit 1
fi

EXEC_NAME="studiomc_services"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) EXEC_NAME="studiomc_services.exe" ;;
esac

if [ ! -f "$DIST_DIR/$EXEC_NAME" ]; then
    echo "✗ Build failed — executable not found at $DIST_DIR/$EXEC_NAME"
    exit 1
fi

chmod +x "$DIST_DIR/$EXEC_NAME" 2>/dev/null || true

if [ ! -x "$DIST_DIR/_internal/bin/$LLAMA_BIN_NAME" ] && [ ! -f "$DIST_DIR/_internal/bin/$LLAMA_BIN_NAME" ]; then
    echo "✗ Build failed — llama-server missing from $DIST_DIR/_internal/bin"
    exit 1
fi
chmod +x "$DIST_DIR/_internal/bin/$LLAMA_BIN_NAME" 2>/dev/null || true

# ── 7. Smoke-test the frozen bundle ─────────────────────────────────────
# Every historical "backend not connecting in production" bug was a
# module that imported fine in the dev venv and failed inside the frozen
# bundle. Catch that here, on the build machine, not on the user's.

if [ "${SKIP_BUNDLE_SMOKE:-0}" != "1" ]; then
    echo "→ Smoke-testing the frozen bundle…"
    python "$SCRIPT_DIR/smoke_bundle.py" --bundle "$DIST_DIR"
fi

BUNDLE_SIZE="$(du -sh "$DIST_DIR" | cut -f1)"
FILE_COUNT="$(find "$DIST_DIR" -type f | wc -l | tr -d ' ')"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ Services bundle built                            ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Output:  $DIST_DIR"
echo "║  Size:    $BUNDLE_SIZE"
echo "║  Files:   $FILE_COUNT"
echo "╚══════════════════════════════════════════════════════╝"
