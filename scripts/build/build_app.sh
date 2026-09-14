#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────
# build_app.sh — Platform-agnostic build (services + Flutter + embed)
#
# Detects the current OS and delegates to the platform-specific build.
# Used by Makefile targets that don't specify a platform explicitly
# (e.g. make build-app, make build-linux).
#
# Usage:
#   bash scripts/build/build_app.sh [--skip-services] [--skip-flutter] [--clean]
# ──────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FLUTTER_DIR="$PROJECT_ROOT/studiomc_app"
SERVICES_DIR="$PROJECT_ROOT/services"

SKIP_SERVICES=false
SKIP_FLUTTER=false
CLEAN=false

for arg in "$@"; do
    case $arg in
        --skip-services) SKIP_SERVICES=true ;;
        --skip-flutter)  SKIP_FLUTTER=true ;;
        --clean)         CLEAN=true ;;
    esac
done

OS="$(uname -s)"

case "$OS" in
    Darwin)
        echo "Detected macOS — delegating to build_macos.sh"
        exec bash "$SCRIPT_DIR/build_macos.sh" "$@"
        ;;
    Linux)
        echo "✗ Linux desktop builds are not shipped." >&2
        echo "  Studiomc supports macOS Apple Silicon and Windows only." >&2
        echo "  The studiomc_app/linux/ scaffold remains for Flutter dev only." >&2
        exit 1
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Detected Windows — use scripts/build_windows.ps1 instead"
        echo "  powershell -File scripts/build_windows.ps1"
        exit 1
        ;;
    *)
        echo "✗ Unsupported platform: $OS"
        exit 1
        ;;
esac
