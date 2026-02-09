# Section: Models

## Overview
Unified model library across all backends. The app auto-detects Ollama and LM Studio, includes its own AirLLM engine, and optionally connects to frontier APIs. Users see one list — the app recommends the best model regardless of where it runs. Manual import (HF ID / local path / Ollama pull) hidden in advanced settings.

## Shell Integration
Inside shell — accessible via sidebar navigation or top bar model indicator.

## Model Backends

| Backend | Type | Detection | User action needed |
|---------|------|-----------|-------------------|
| **Ollama** | Local (preferred) | Auto-detected on `localhost:11434` | None — just have Ollama running |
| **LM Studio** | Local (preferred) | Auto-detected on `localhost:1234` | None — just have LM Studio running |
| **AirLLM** (built-in) | Local | Always available | None — ships with app |
| **HuggingFace** | Local (download) | Via model manager | Enter model ID in advanced settings |
| **Frontier APIs** | Cloud (optional) | User-configured | Add API key in Settings → Advanced |

### Backend badges (shown on model cards)
- "Local via Ollama" (green)
- "Local via LM Studio" (green)
- "Local via Studiomc" (green)
- "Cloud via OpenAI" (amber with lock icon)
- "Cloud via Anthropic" (amber with lock icon)

### Auto-detection behavior
1. On app launch, Supervisor probes Ollama (`localhost:11434`) and LM Studio (`localhost:1234`)
2. If found: their loaded models merge into the unified list
3. If not found: no error — AirLLM engine is always available as fallback
4. User can trigger re-scan from Models screen ("Refresh backends")
5. Autopilot recommends across ALL available backends

### Routing priority
- Local backends always preferred over cloud
- Same model available on multiple backends: Ollama > LM Studio > AirLLM
- Frontier APIs only used when user explicitly selects a cloud model
- First cloud request shows consent modal: "This sends your message to [provider]. Your data leaves your device."

## Layout
- **Recommended** (top): auto-selected best model for this machine across all backends, with speed badge + backend badge
- **Installed / Available**: models grouped by backend with status, size, last used
- **Discover**: curated list + Ollama library models filtered by hardware compatibility
- **Import** (advanced only): HF model ID, Ollama model name (`ollama pull`), or local file picker

## User Flows

### Flow 1: View Models
1. Tap "Models" in sidebar (or model name in top bar)
2. See recommended model highlighted at top (may be from any backend)
3. Available models listed below grouped by backend, each with speed rating + size + backend badge
4. "Discover more" section shows compatible curated models

### Flow 2: Switch Model
1. Tap a different model
2. App shows predicted speed rating for that model on current hardware
3. If "Painful": show guardrail modal (slow warning + recommended alternative + explanation of smart memory management)
4. If cloud model: show privacy consent modal on first use
5. If accepted: model loads via its backend, top bar updates with backend badge

### Flow 3: Download New Model
1. Browse Discover section → tap model → "Download"
2. If Ollama backend: runs `ollama pull` under the hood
3. If HuggingFace/AirLLM: direct download with progress bar, pause/resume, checksum verification
4. Model appears in Installed list with correct backend badge

### Flow 4: Add Frontier API (Advanced)
1. Settings → Advanced → Model Backends → "Add cloud provider"
2. Select provider (OpenAI, Anthropic, Google, Mistral, or custom OpenAI-compatible)
3. Enter API key (masked, stored encrypted in OS keychain)
4. Provider's models appear in the unified list with "Cloud" badge
5. Privacy warning shown: "Cloud models send data to external servers"

### Flow 5: Import (Advanced)
1. Settings → Advanced → Import Model
2. Options: Enter HF model ID / Enter Ollama model name / Browse local path
3. Micro-benchmark runs
4. Model added to Installed with appropriate backend

## Smart Memory Management (user-facing)
When Autopilot recommends a model that would normally be too large:
- Show explanation: "This model is larger than your hardware usually supports, but Studiomc's smart memory management makes it work"
- Speed rating accounts for out-of-core overhead (honest)
- If CLaRa is active: note that document queries will be faster due to compressed retrieval
- Guardrail modal updated: instead of just "this will be slow", show "Studiomc can run this model using disk streaming — it will be [speed rating] but functional"

## UI Requirements
- Model card: name, param count (plain language: "8 billion parameters"), size ("4.2 GB"), speed badge, backend badge, "Active" indicator
- Backend badge: colored pill (green for local, amber for cloud)
- Guardrail modal for painful models with smart memory context
- Privacy consent modal for first cloud model use
- Download progress inline on model card
- "Refresh backends" button to re-scan for Ollama/LM Studio
- No delete unless in advanced settings
- Curated models: show "Works well on your machine" vs "May be slow (smart memory can help)"

## Scope Boundaries
- No model fine-tuning
- No model comparison benchmarks (just speed rating)
- No quantization selection (app auto-picks best quant)
- No auto-download of Ollama/LM Studio — user must install those themselves
