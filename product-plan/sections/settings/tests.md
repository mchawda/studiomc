# Tests: Settings

## Privacy
- Default: local-only toggle is ON
- Default: telemetry opt-in is OFF
- Toggle telemetry on: verify persists across restart

## Appearance
- Select Light Blue theme: verify app updates immediately
- Select Dark Blue theme: verify dark mode applies
- Select custom color: verify color picker and live preview
- Toggle dark/light: verify switches correctly and persists

## About
- Verify app version displays
- Tap "Open Source Licenses": verify THIRD_PARTY_NOTICES loads
- Verify license texts are scrollable and readable
- Verify NOTICE file content displays

## Advanced Toggle
- Default: advanced sections hidden
- Toggle on: verify Model Import, API, Performance, Diagnostics, Folders appear
- Toggle off: verify they collapse
- Verify toggle state persists

## Model Import (Advanced)
- Enter HF model ID: verify download starts + micro-benchmark runs
- Browse local path: verify file picker opens + model added
- Invalid model: verify error message

## API Endpoints (Advanced)
- Toggle local API on: verify localhost URL + API key display
- Toggle off: verify server stops
- Add frontier API key: verify masked input with show/hide
- Verify API keys persist (encrypted)

## Performance Tuning (Advanced)
- Adjust context length slider: verify value updates
- Adjust batch size: verify value updates
- Verify changes apply to inference service

## Diagnostics (Advanced)
- View benchmarks: verify results display
- View logs: verify log content loads
- Export diagnostics: verify file generated without chat content

## Folder Access (Advanced)
- Add folder: verify OS file picker opens, folder added to list
- Revoke folder: verify removed from list
- Verify LRE respects folder list
