# ══════════════════════════════════════════════════════════════════════════
# Studiomc — Top-level Makefile
#
# Usage:
#   make dev             — Start backend + Flutter app in dev mode
#   make services        — Start Python services only (dev mode)
#   make build-services  — Bundle Python services with PyInstaller
#   make build-macos     — Full macOS build (.app with embedded Python)
#   make release-macos   — Build + create .dmg installer
#   make clean           — Remove all build artifacts
# ══════════════════════════════════════════════════════════════════════════

.PHONY: help dev services flutter \
        build-services build-app build-macos build-linux \
        build-ios build-android \
        release-macos release-linux \
        clean clean-services clean-flutter \
        check-deps

# Default target
help:
	@echo "Studiomc Build System"
	@echo "═════════════════════"
	@echo ""
	@echo "Development:"
	@echo "  make dev              Start backend + Flutter (macOS)"
	@echo "  make services         Start Python services only"
	@echo "  make flutter          Start Flutter app only (hot-reload)"
	@echo ""
	@echo "Build:"
	@echo "  make build-services   Bundle Python services (PyInstaller)"
	@echo "  make build-app        Build services + Flutter app"
	@echo "  make build-macos      Full macOS build with embedded Python"
	@echo "  make build-linux      Full Linux build with embedded Python"
	@echo "  make build-ios        Build iOS app (no Python backend)"
	@echo "  make build-android    Build Android APK (no Python backend)"
	@echo ""
	@echo "Release:"
	@echo "  make release-macos    Build + create .dmg installer"
	@echo "  make release-linux    Build + create .AppImage"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean            Remove all build artifacts"
	@echo "  make check-deps       Verify toolchain is installed"

# ── Temp directory (keep boot disk free) ────────────────────────────────
# Flutter/Dart write large compile artifacts to TMPDIR.
# Redirect to the external drive so the small macOS boot disk isn't filled.
EXT_TMP := /Volumes/External Drive/system/tmp
export TMPDIR := $(EXT_TMP)

# ── Development ──────────────────────────────────────────────────────────

dev: _ensure-tmp services-bg flutter

services:
	@echo "Starting Python services (supervisor)…"
	cd services && . .venv/bin/activate && python supervisor/app.py

# Start services in background, then launch Flutter
services-bg:
	@echo "Starting services in background…"
	@cd services && . .venv/bin/activate && python supervisor/app.py &
	@echo "Waiting for supervisor to come up…"
	@sleep 3

flutter: _ensure-tmp
	@echo "Starting Flutter app… (TMPDIR=$(TMPDIR))"
	cd studiomc_app && flutter run -d macos

_ensure-tmp:
	@mkdir -p "$(EXT_TMP)"

# ── Build ────────────────────────────────────────────────────────────────

build-services:
	bash scripts/build/build_services.sh

build-app: build-services
	bash scripts/build/build_app.sh --skip-services

build-macos: build-services
	bash scripts/build/build_macos.sh --skip-services

build-linux: build-services
	bash scripts/build/build_app.sh --skip-services

# ── Mobile builds (no Python backend — on-device inference only) ──

build-ios: _ensure-tmp
	@echo "Building iOS app…"
	cd studiomc_app && flutter build ios --release

build-android: _ensure-tmp
	@echo "Building Android APK…"
	cd studiomc_app && flutter build apk --release --split-per-abi

# ── Release ──────────────────────────────────────────────────────────────

release-macos: build-macos
	bash scripts/release/macos_dmg.sh

release-linux: build-linux
	bash scripts/release/linux_appimage.sh

# ── Clean ────────────────────────────────────────────────────────────────

clean: clean-services clean-flutter
	@rm -rf dist/
	@echo "✓ All build artifacts cleaned"

clean-services:
	@echo "Cleaning services build…"
	@rm -rf services/dist/ services/build/
	@rm -rf studiomc_app/build/_services_stage/

clean-flutter:
	@echo "Cleaning Flutter build…"
	@cd studiomc_app && flutter clean

# ── Dependency check ─────────────────────────────────────────────────────

check-deps:
	@echo "Checking toolchain…"
	@echo -n "  Python:      " && python3 --version
	@echo -n "  Flutter:     " && flutter --version | head -1
	@echo -n "  Dart:        " && dart --version
	@if [ -d "services/.venv" ]; then echo "  Venv:        ✓ services/.venv"; else echo "  Venv:        ✗ missing"; fi
	@echo -n "  PyInstaller: " && (cd services && . .venv/bin/activate && python -m PyInstaller --version 2>/dev/null || echo "not installed")
	@echo ""
	@echo "Platform tools:"
	@if command -v create-dmg >/dev/null 2>&1; then echo "  create-dmg:  ✓"; else echo "  create-dmg:  ✗ (brew install create-dmg)"; fi
	@if command -v appimagetool >/dev/null 2>&1; then echo "  appimagetool: ✓"; else echo "  appimagetool: ✗ (for Linux AppImage)"; fi
