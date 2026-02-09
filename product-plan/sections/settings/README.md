# Section: Settings

## Overview
Privacy, theme, and basic preferences in default view. Advanced toggle reveals: model import, API endpoints (local + frontier), performance tuning, diagnostics, logs, support bundle, about/licenses.

## Shell Integration
Inside shell — accessible via gear icon at bottom of sidebar.

## Layout
- **Default view**: clean list of setting groups (Privacy, Appearance, About)
- **Advanced view** (behind toggle): additional groups appear (Models, API, Performance, Diagnostics)

## User Flows

### Flow 1: Change Theme
1. Settings → Appearance → Theme
2. Two recommended defaults (light blue, dark blue) + custom color picker
3. Preview updates live

### Flow 2: Toggle Advanced Settings
1. Settings → scroll to bottom → "Show Advanced Settings" toggle
2. Additional sections appear: Model Import, API Endpoints, Performance Tuning, Diagnostics

### Flow 3: Import Model (Advanced)
1. Settings → Advanced → Model Import
2. Enter HuggingFace model ID or browse local path
3. Micro-benchmark runs → model added to library

### Flow 4: Configure API (Advanced)
1. Settings → Advanced → API Endpoints
2. Local API: toggle on/off, shows localhost URL + generated API key
3. Frontier APIs: add API keys for OpenAI, Anthropic, etc.

### Flow 5: Export Diagnostics (Advanced)
1. Settings → Advanced → Diagnostics → "Export diagnostics"
2. Generates sanitized bundle → save to file
3. Never includes chat content unless explicitly toggled

### Flow 6: View Licenses
1. Settings → About → "Open Source Licenses"
2. Displays THIRD_PARTY_NOTICES
3. Full license texts viewable
4. NOTICE file viewable

## Setting Groups

### Default
| Group | Settings |
|-------|----------|
| **Privacy** | Local-only mode (default on), opt-in telemetry toggle |
| **Appearance** | Theme (2 recommended + custom), dark/light mode |
| **About** | Version, open source licenses, support link |

### Advanced (behind toggle)
| Group | Settings |
|-------|----------|
| **Model Import** | HF model ID, local path, delete models |
| **API Endpoints** | Local API toggle + URL/key, frontier API keys |
| **Performance** | Context length, batch size, prefetch depth, threading |
| **Diagnostics** | Benchmarks, logs viewer, system status, export bundle |
| **Folder Access** | Approved folders for LRE, add/revoke permissions |

## UI Requirements
- Clean grouped list with section headers
- Toggle switches for on/off settings
- Advanced toggle: prominent but not scary, "Show Advanced Settings"
- Theme preview: live preview swatch
- API key fields: masked with show/hide toggle
- Diagnostics export: single button with progress
- Licenses: scrollable text view

## Scope Boundaries
- No cloud sync settings (local only)
- No user account management (single user)
- No keyboard shortcut customization (future)
