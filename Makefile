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
        fetch-llama-server build-pro-pack \
        train-studiomc-4b-dry \
        build-services build-app build-macos build-linux \
        build-ios build-android \
        test-mobile-inference mobile-inference \
        release-macos release-linux \
        smoke-fresh-install smoke-bundle test-services \
        clean clean-services clean-flutter clean-llama clean-pro-pack \
        check-deps eval

# Default target
help:
	@echo "Studiomc Build System"
	@echo "═════════════════════"
	@echo ""
	@echo "Development:"
	@echo "  make dev              Start backend + Flutter (macOS)"
	@echo "  make services         Start Python services only"
	@echo "  make flutter          Start Flutter app only (hot-reload)"
	@echo "  make train-studiomc-4b-dry  Format Studiomc 4B SFT data (no GPU)"
	@echo ""
	@echo "Build:"
	@echo "  make fetch-llama-server  Download llama-server binary into services/bin/"
	@echo "  make build-pro-pack      Build the optional Pro pack tarball (~1 GB)"
	@echo "  make build-services      Bundle Python services (PyInstaller; auto fetches llama-server)"
	@echo "  make build-app           Build services + Flutter app"
	@echo "  make build-macos      Full macOS build with embedded Python"
	@echo "  make build-linux      Full Linux build with embedded Python"
	@echo "  make build-ios        Build iOS app (no Python backend)"
	@echo "  make build-android    Build Android APK (no Python backend)"
	@echo "  make test-mobile-inference  Flutter tests for on-device inference"
	@echo "  make mobile-inference       Print the llama.cpp mobile follow-up"
	@echo ""
	@echo "Release:"
	@echo "  make release-macos    Build + create .dmg installer"
	@echo "  make release-linux    Build + create .AppImage"
	@echo ""
	@echo "Verification:"
	@echo "  make test-services         Python unit tests (Core/Pro boundary, spec, health)"
	@echo "  make smoke-bundle          Launch services/dist bundle with a clean data dir, assert /health"
	@echo "  make smoke-fresh-install   Same against the built .app (GGUF=path/to/small.gguf for a real chat)"
	@echo ""
	@echo "Evaluation:"
	@echo "  make eval             Run grounded-answering eval tests + offline scorer"
	@echo ""
	@echo "Maintenance:"
	@echo "  make clean            Remove all build artifacts"
	@echo "  make check-deps       Verify toolchain is installed"

# ── Temp directory (keep boot disk free) ────────────────────────────────
# Flutter/Dart write large compile artifacts to TMPDIR.
# Redirect to the external drive so the small macOS boot disk isn't filled.
# Only override if the external drive is actually mounted.
EXT_TMP := /Volumes/External Drive/system/tmp
ifneq ($(wildcard /Volumes/External Drive),)
export TMPDIR := $(EXT_TMP)
endif

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
ifdef TMPDIR
	@mkdir -p "$(TMPDIR)"
endif

# ── Studiomc 4B specialized model (no GPU) ───────────────────────────────

train-studiomc-4b-dry:
	cd services && python -m training.studiomc_model dry-run

# ── Build ────────────────────────────────────────────────────────────────

fetch-llama-server:
	bash scripts/build/fetch_llama_server.sh

build-pro-pack:
	bash scripts/build/build_pro_pack.sh

build-services: fetch-llama-server
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

# Host-side tests. Does not compile an iOS/Android release.
test-mobile-inference: _ensure-tmp
	cd studiomc_app && flutter test test/mobile_inference/

# Contract reminder for the session that links llama.cpp on device.
mobile-inference:
	@echo "On-device inference (no Python)"
	@echo "  Dart:     studiomc_app/lib/services/mobile_inference/"
	@echo "  Tests:    make test-mobile-inference"
	@echo "  Channel:  studiomc.mobile_inference  (probe/load/unload/complete/streamStart/streamCancel/embed)"
	@echo "  Tokens:   studiomc.mobile_inference/tokens"
	@echo "  Models:   Application Support/models/<id>/<file>.gguf"
	@echo "  iOS/Android probe is live. load/complete still return llama_cpp_not_linked."
	@echo "  Next:     ship GGUF + implement load/complete in MobileInferenceHost via llama.cpp"

# ── Verification ─────────────────────────────────────────────────────────
# The frozen bundle is what users run; the dev venv is not. These targets
# launch the real artefact with an empty STUDIOMC_HOME and assert the
# first-launch path (supervisor /health, every child healthy, llama-server
# found, hardware scan + recommendation, clean shutdown, no stale pids).
#
#   make smoke-fresh-install                         # built .app
#   make smoke-fresh-install GGUF=~/models/tiny.gguf  # + real chat completion
#   make smoke-fresh-install DOWNLOAD=bartowski/Llama-3.2-1B-Instruct-GGUF

SMOKE_ARGS :=
ifdef GGUF
SMOKE_ARGS += --gguf "$(GGUF)"
endif
ifdef DOWNLOAD
SMOKE_ARGS += --download "$(DOWNLOAD)"
endif

test-services:
	cd services && . .venv/bin/activate && PYTHONPATH=. python -m pytest -q

smoke-bundle:
	python3 scripts/build/smoke_bundle.py --bundle services/dist/studiomc_services $(SMOKE_ARGS)

smoke-fresh-install:
	@APP="$$(ls -d studiomc_app/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1)"; \
	if [ -z "$$APP" ]; then \
		APP="studiomc_app/build/linux/x64/release/bundle"; \
	fi; \
	if [ ! -e "$$APP" ]; then echo "✗ No built app found. Run: make build-macos (or make build-linux)"; exit 1; fi; \
	echo "Smoke-testing fresh install of $$APP"; \
	python3 scripts/build/smoke_bundle.py --app "$$APP" $(SMOKE_ARGS)

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

clean-llama:
	@echo "Cleaning llama-server binaries…"
	@rm -rf services/bin/

clean-pro-pack:
	@echo "Cleaning Pro pack build artifacts…"
	@rm -rf dist/pro-pack/

# ── Grounded-answering eval (no GPU, no torch) ──────────────────────────

eval:
	@echo "Running grounded-answering eval harness…"
	cd services && . .venv/bin/activate && PYTHONPATH=. python -m pytest tests/test_eval_harness.py -q
	cd services && . .venv/bin/activate && PYTHONPATH=. python -m eval

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
