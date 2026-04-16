# macOS Code Signing and Notarization

## The Problem

The app is unsigned, so macOS Gatekeeper blocks installation with "unidentified developer" or moves the app to trash. Users must know to right-click > Open to bypass — most won't.

## What You Need to Do (manual, one-time) — DONE

- [x] Sign up for Apple Developer Program
- [x] Create a Developer ID Application certificate in Xcode
- [x] Create an app-specific password for notarization
- [x] Get your Team ID
- [x] Export the certificate as a `.p12` file for CI
- [x] Add GitHub Actions secrets

## Implementation — DONE

- [x] **CI workflow** (`release.yml`) — Added certificate import, codesign, notarization, and stapling steps to both `macos-arm64` and `macos-intel` jobs
- [x] **Xcode project** (`project.pbxproj`) — Set `CODE_SIGN_IDENTITY = "Developer ID Application"`, `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM`, and `ENABLE_HARDENED_RUNTIME = YES` for Release
- [x] **Release.entitlements** — Verified correct (sandbox disabled, network + file access enabled)
- [x] **README** — Removed Gatekeeper bypass note

## Build Pipeline — DONE

- [x] **`scripts/build/build_services.sh`** — Bundle Python services with PyInstaller into `services/dist/studiomc_services/`
- [x] **`scripts/build/build_macos.sh`** — Full macOS build: services → Flutter → embed into .app
- [x] **`scripts/build/build_app.sh`** — Platform-agnostic build dispatcher (macOS delegates to `build_macos.sh`, Linux builds inline)
- [x] **`scripts/build_macos.sh`** — Wrapper that delegates to `scripts/build/build_macos.sh` (backwards compat)
- [x] **`scripts/build-macos.sh`** — Convenience wrapper: build + DMG in one step
- [x] **`Makefile`** — All targets resolve (`make build-services`, `make build-macos`, `make build-app`, `make build-linux`, `make release-macos`, `make release-linux`)
- [x] **CI references verified** — `release.yml` calls `scripts/build/build_services.sh` and `scripts/build/build_macos.sh`, both exist

## Result

Push a tag to trigger the full pipeline:

```
git tag v1.1.0 && git push --tags
```

```
Tag → Flutter build → codesign → DMG → notarytool → stapler → GitHub Release
```

Users download the DMG, open it, drag to Applications, and launch — no warnings.
