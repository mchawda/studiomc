# Milestone 9: Settings

## Goal
Privacy, theme, and advanced configuration with license compliance.

## Tasks
1. Settings screen: grouped list with section headers
2. **Privacy**: local-only toggle (default on), telemetry opt-in toggle
3. **Appearance**: theme picker (Light Blue, Dark Blue recommended + custom picker), dark/light toggle, live preview
4. **About**: app version, "Open Source Licenses" button → scrollable view of THIRD_PARTY_NOTICES + license texts + NOTICE file
5. **Advanced toggle** at bottom: "Show Advanced Settings"
6. **Model Import** (advanced): HF model ID text field, local path file picker, triggers micro-benchmark
7. **API Endpoints** (advanced): local API on/off toggle + localhost URL + generated API key, frontier API keys (OpenAI, Anthropic etc.) with masked input + show/hide
8. **Performance Tuning** (advanced): sliders for context length, batch size, prefetch depth, thread count
9. **Diagnostics** (advanced): benchmark results view, log viewer, system status, export bundle button
10. **Folder Access** (advanced): list of approved folders for LRE, add folder (OS file picker), revoke button
11. Persist all settings to SQLite settings table
12. License artifacts: create THIRD_PARTY_NOTICES.md, LICENSES/ directory, NOTICE file

## Reference
- `sections/settings/spec.md`, `types.ts`, `data.json`
- `product/security-and-licensing.md` for compliance requirements

## Acceptance
- All settings persist across app restart
- Theme changes apply immediately
- Advanced toggle reveals/hides additional sections
- License view shows all third-party notices
- Diagnostics export works
- Local API can be toggled on (starts server) and off
- Folder permissions can be added/revoked
