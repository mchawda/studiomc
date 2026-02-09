#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# bundle_python.sh — Bundle all Python services into a self-contained directory
#
# This script uses PyInstaller to compile the supervisor + all microservices
# into a single-directory bundle that includes a frozen Python interpreter
# and every pip dependency. The result requires NO system Python to run.
#
# Output:
#   services/dist/studiomc_services/    — the standalone bundle
#
# The bundle is then staged into the Flutter app's platform-specific
# resources directory so that build_macos.sh / build_windows.ps1 can
# embed it inside the final application package.
#
# Usage:
#   bash scripts/bundle_python.sh [--stage-macos] [--stage-windows] [--clean]
#
# Options:
#   --stage-macos     Copy bundle into studiomc_app/macos/Runner/Resources/python_backend/
#   --stage-windows   Copy bundle into studiomc_app/build/_services_stage/
#   --clean           Remove previous build artifacts before building
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"
VENV_DIR="$SERVICES_DIR/.venv"

STAGE_MACOS=false
STAGE_WINDOWS=false
CLEAN=false

for arg in "$@"; do
    case $arg in
        --stage-macos)   STAGE_MACOS=true ;;
        --stage-windows) STAGE_WINDOWS=true ;;
        --clean)         CLEAN=true ;;
        -h|--help)
            echo "Usage: bash scripts/bundle_python.sh [--stage-macos] [--stage-windows] [--clean]"
            exit 0
            ;;
    esac
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — Python Services Bundler                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Verify prerequisites ──────────────────────────────────────────────

if [ ! -d "$VENV_DIR" ]; then
    echo "✗ Virtual environment not found at $VENV_DIR"
    echo ""
    echo "  Set it up with:"
    echo "    cd services"
    echo "    python3 -m venv .venv"
    echo "    source .venv/bin/activate"
    echo "    pip install -r requirements.txt"
    exit 1
fi

# Activate the venv so we use the project's Python + all pip packages
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
echo "✓ Activated venv: $(which python)"
echo "  Python version: $(python --version 2>&1)"

# ── 2. Ensure PyInstaller is available ────────────────────────────────────

if ! python -m PyInstaller --version &>/dev/null; then
    echo "→ Installing PyInstaller…"
    pip install pyinstaller
fi
PYINSTALLER_VER="$(python -m PyInstaller --version 2>&1)"
echo "✓ PyInstaller $PYINSTALLER_VER"

# Verify the spec file exists
SPEC_FILE="$SERVICES_DIR/studiomc_services.spec"
if [ ! -f "$SPEC_FILE" ]; then
    echo "✗ PyInstaller spec not found at $SPEC_FILE"
    exit 1
fi
echo "✓ Spec file: $SPEC_FILE"
echo ""

# ── 3. Clean previous artifacts ──────────────────────────────────────────

DIST_DIR="$SERVICES_DIR/dist/studiomc_services"
BUILD_DIR="$SERVICES_DIR/build/studiomc_services"

if [ "$CLEAN" = true ] || [ -d "$DIST_DIR" ]; then
    echo "→ Cleaning previous build artifacts…"
    rm -rf "$DIST_DIR"
    rm -rf "$BUILD_DIR"
    echo "✓ Clean"
fi

# ── 4. Run PyInstaller ───────────────────────────────────────────────────

echo "→ Running PyInstaller (this may take a few minutes)…"
echo ""

cd "$SERVICES_DIR"
python -m PyInstaller studiomc_services.spec --clean --noconfirm

echo ""

# ── 5. Verify the bundle ────────────────────────────────────────────────

if [ ! -d "$DIST_DIR" ]; then
    echo "✗ Build failed — output directory not found at $DIST_DIR"
    exit 1
fi

# Check for the main executable
EXEC_NAME="studiomc_services"
if [ "$(uname -s)" = "MINGW"* ] || [ "$(uname -s)" = "MSYS"* ]; then
    EXEC_NAME="studiomc_services.exe"
fi

if [ ! -f "$DIST_DIR/$EXEC_NAME" ]; then
    echo "✗ Build failed — executable not found at $DIST_DIR/$EXEC_NAME"
    exit 1
fi

chmod +x "$DIST_DIR/$EXEC_NAME" 2>/dev/null || true

BUNDLE_SIZE="$(du -sh "$DIST_DIR" | cut -f1)"
FILE_COUNT="$(find "$DIST_DIR" -type f | wc -l | tr -d ' ')"

echo "✓ Bundle built successfully!"
echo "  Output:    $DIST_DIR"
echo "  Size:      $BUNDLE_SIZE"
echo "  Files:     $FILE_COUNT"
echo "  Binary:    $DIST_DIR/$EXEC_NAME"
echo ""

# ── 6. Stage into platform-specific locations ────────────────────────────

if [ "$STAGE_MACOS" = true ]; then
    MACOS_DEST="$FLUTTER_DIR/macos/Runner/Resources/python_backend"
    echo "→ Staging for macOS: $MACOS_DEST"
    rm -rf "$MACOS_DEST"
    mkdir -p "$MACOS_DEST"
    cp -R "$DIST_DIR"/* "$MACOS_DEST/"
    chmod +x "$MACOS_DEST/studiomc_services"
    echo "✓ macOS staging complete ($(du -sh "$MACOS_DEST" | cut -f1))"
    echo ""
fi

if [ "$STAGE_WINDOWS" = true ]; then
    WIN_DEST="$FLUTTER_DIR/build/_services_stage"
    echo "→ Staging for Windows: $WIN_DEST"
    rm -rf "$WIN_DEST"
    mkdir -p "$WIN_DEST"
    cp -R "$DIST_DIR"/* "$WIN_DEST/"
    echo "✓ Windows staging complete ($(du -sh "$WIN_DEST" | cut -f1))"
    echo ""
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✓ Python bundling complete                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  • macOS:   bash scripts/build_macos.sh"
echo "  • Windows: powershell scripts/build_windows.ps1"
echo "  • Test:    $DIST_DIR/studiomc_services --help"
