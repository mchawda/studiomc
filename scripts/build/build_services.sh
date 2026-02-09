#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_services.sh — Bundle all Python services into a standalone directory
#
# Output: services/dist/studiomc_services/
#   A self-contained directory with the studiomc_services executable and all
#   its dependencies.  No system Python required to run.
#
# Usage:
#   bash scripts/build/build_services.sh
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SERVICES_DIR="$PROJECT_ROOT/services"
VENV_DIR="$SERVICES_DIR/.venv"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Studiomc — Build Python Services Bundle            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Verify virtual environment ────────────────────────────────────────
if [ ! -d "$VENV_DIR" ]; then
    echo "✗ Virtual environment not found at $VENV_DIR"
    echo "  Run: cd services && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
echo "✓ Activated venv: $(which python)"

# ── 2. Ensure PyInstaller is installed ───────────────────────────────────
if ! python -m PyInstaller --version &>/dev/null; then
    echo "→ Installing PyInstaller…"
    pip install pyinstaller
fi
echo "✓ PyInstaller $(python -m PyInstaller --version)"

# ── 3. Clean previous build artifacts ───────────────────────────────────
echo "→ Cleaning previous build…"
rm -rf "$SERVICES_DIR/dist/studiomc_services"
rm -rf "$SERVICES_DIR/build/studiomc_services"

# ── 4. Run PyInstaller ──────────────────────────────────────────────────
echo "→ Running PyInstaller (this may take a few minutes)…"
cd "$SERVICES_DIR"
python -m PyInstaller studiomc_services.spec --clean --noconfirm

# ── 5. Verify output ───────────────────────────────────────────────────
BUNDLE_DIR="$SERVICES_DIR/dist/studiomc_services"
if [ ! -f "$BUNDLE_DIR/studiomc_services" ]; then
    echo "✗ Build failed — executable not found at $BUNDLE_DIR/studiomc_services"
    exit 1
fi

BUNDLE_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
echo ""
echo "✓ Build complete!"
echo "  Output:  $BUNDLE_DIR"
echo "  Size:    $BUNDLE_SIZE"
echo "  Binary:  $BUNDLE_DIR/studiomc_services"
