# Section: Settings

## Overview
Privacy, theme, and basic preferences in default view. Advanced toggle reveals: model import, model backends (Ollama, LM Studio, frontier APIs), performance tuning, diagnostics, logs, support bundle, about/licenses.

## Shell Integration
Inside shell — accessible via gear icon at bottom of sidebar.

## Layout
- **Default view**: clean list of setting groups (Privacy, Appearance, About)
- **Advanced view** (behind toggle): additional groups appear (Model Import, Model Backends, Performance, Diagnostics)

## User Flows

### Flow 1: Change Theme
1. Settings → Appearance → Theme
2. Two recommended defaults (light blue, dark blue) + custom color picker
3. Preview updates live

### Flow 2: Toggle Advanced Settings
1. Settings → scroll to bottom → "Show Advanced Settings" toggle
2. Additional sections appear: Model Import, Model Backends, Performance Tuning, Diagnostics

### Flow 3: Import Model (Advanced)
1. Settings → Advanced → Model Import
2. Three options:
   - Enter HuggingFace model ID
   - Enter Ollama model name (runs `ollama pull`)
   - Browse local file path
3. Micro-benchmark runs → model added to library

### Flow 4: Configure Model Backends (Advanced)
1. Settings → Advanced → Model Backends
2. **Local backends** section:
   - Ollama: auto-detected status (green "Connected" / grey "Not found"), endpoint URL (default: `localhost:11434`), "Re-scan" button
   - LM Studio: auto-detected status, endpoint URL (default: `localhost:1234`), "Re-scan" button
   - AirLLM (built-in): always available, shows memory management status
3. **Cloud providers** section:
   - "Add cloud provider" button
   - Provider picker: OpenAI, Anthropic, Google, Mistral, Custom (OpenAI-compatible)
   - API key field (masked, stored in OS keychain)
   - Custom endpoint URL (for self-hosted or other compatible APIs)
   - Per-provider toggle: enable/disable without deleting key
   - Privacy notice: "Cloud models send your messages to external servers"
4. **Local API** section:
   - Toggle on/off local OpenAI-compatible endpoint
   - Shows localhost URL + generated API key

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
| **Model Import** | HF model ID, Ollama model name, local path, delete models |
| **Model Backends** | Ollama connection status/URL, LM Studio connection status/URL, AirLLM status, cloud provider API keys (OpenAI/Anthropic/Google/Mistral/custom), local API toggle + URL/key |
| **Performance** | Context length, batch size, prefetch depth, threading |
| **Diagnostics** | Benchmarks, logs viewer, system status, export bundle |
| **Folder Access** | Approved folders for LRE, add/revoke permissions |

## UI Requirements
- Clean grouped list with section headers
- Toggle switches for on/off settings
- Advanced toggle: prominent but not scary, "Show Advanced Settings"
- Theme preview: live preview swatch
- Backend status: green dot "Connected" / grey dot "Not found" for auto-detected backends
- Cloud provider cards: provider logo, masked API key with show/hide, enable/disable toggle, delete button
- Privacy notice on cloud section: amber banner "Cloud providers receive your messages"
- API key fields: masked with show/hide toggle, stored encrypted
- Diagnostics export: single button with progress
- Licenses: scrollable text view

## Scope Boundaries
- No cloud sync settings (local only)
- No user account management (single user)
- No keyboard shortcut customization (future)
- No auto-install of Ollama or LM Studio — user installs those independently
