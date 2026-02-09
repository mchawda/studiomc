# UX/UI Specification

## Information Architecture
- **Home** — "New Chat", recent chats, quick actions (upload doc, settings)
- **Chat** — Conversation list (left), chat stream (center), context panel (right: model + backend badge, mode, doc sources, speed rating)
- **Models** — Recommended across all backends (top), installed/available grouped by backend, discover (curated + Ollama library), import (HF ID/Ollama name/local — advanced only)
- **Documents** — Library, collections (folders), "Chat with this document"
- **Settings** — Privacy, appearance, about. Advanced toggle → model import, model backends (Ollama/LM Studio status, cloud provider API keys), performance tuning, diagnostics, logs, support bundle, about/licenses
- **Diagnostics** — Benchmarks, logs (export), system status (inside advanced settings)

## Onboarding Flow (critical path)

### Step 1: Welcome
- "Local AI. Private by default."
- Buttons: **Get Started** | **I already have a model**

### Step 2: Hardware Scan + Backend Detection (automatic)
- GPU / VRAM detected (or CPU-only) — displayed as "graphics memory" not "VRAM"
- RAM
- Disk type (NVMe/SATA/Unknown) + measured read speed quick test
- **Backend scan**: probes for Ollama (`localhost:11434`) and LM Studio (`localhost:1234`)
- If Ollama found: shows "Ollama detected — [N] models available" with checkmark
- If LM Studio found: shows "LM Studio detected — [N] models loaded" with checkmark
- If neither found: no error, continues with built-in AirLLM engine
- Results stored keyed by hw_fingerprint

### Step 3: Recommendation (the "magic moment")
- "Best experience for you" — auto-selected from ALL available backends
- If Ollama/LM Studio detected with models: may recommend an already-loaded model (instant, no download)
- If no local backends: recommends from curated list for AirLLM download
- "Bigger models (slower)" (collapsed) — includes note: "Studiomc's smart memory makes larger models possible on your hardware"
- Plain-English explanation:
  - "This model will feel responsive."
  - "This one will be slower due to disk streaming."
- Backend badge shown on recommendation card ("Local via Ollama", "Local via Studiomc")

### Step 4: Download & Verify (skip if model already available)
- If recommended model is already loaded in Ollama/LM Studio: skip download, go to Step 5
- If download needed: progress bar, ETA, resumable, "Pause / resume", "Verify integrity" (checksum)
- If Ollama backend: runs `ollama pull` under the hood

### Step 5: First Chat
- Auto-starts with system prompt: "You are a private local assistant. Ask me anything."

## Chat Experience

### Input Box
- Attach file button
- Mode switch (Writing/Coding/Tutor)
- "Memory toggle" (local memory summary per workspace, user controlled)

### Output
- Streaming tokens
- Copy, regenerate, "continue"
- "Explain sources" for doc answers
- Groundedness meter (% supported by sources, list of sources, "no source found" banner)

### Top Bar
- Model name + backend badge ("Local via Ollama", "Cloud via OpenAI") + speed rating badge
- Mode selector (Chat / Docs / Investigate)

### Conversation Controls
- Rename, pin, export (Markdown)

### User-Facing Modes (one control, no jargon)
- **Chat (Fast)** — normal chat, minimal retrieval
- **Docs (Cited)** — answers with citations, best default for documents
- **Investigate (Deep)** — slower but thorough, model uses tools and recursive sub-queries

### Investigate Mode Trace Panel (collapsible)
- "Search: '...' in Folder X"
- "Opened: Doc A (p3–p4)"
- "Extracted: table rows 12–17"
- "Cited: ..."

### Critical UX Rule
If system cannot find evidence: "I can't find this in your documents. Want me to broaden the search or check another folder?" — No fake confidence.

## UX Guardrails for Huge Models
When user selects model predicted "Painful":
- Modal: "This will be slow on your hardware (estimated 0.3–1.2 tok/s)."
- If smart memory available: "Studiomc can run this model using disk streaming — it will be [speed rating] but functional."
- "Recommended alternative: X (fast)."
- Buttons: **Use recommended** | **Run anyway**
- If "Run anyway", app auto-sets: lower context length, conservative batch sizes, aggressive prefetch, "Slow mode" UI indicator

## Cloud Model Consent
When user selects a frontier/cloud model for the first time:
- Modal: "This will send your message to [provider]. Your data leaves your device."
- "Your local models don't send data anywhere."
- Buttons: **Cancel** | **I understand, continue**
- Consent stored per-provider. Not asked again for same provider.

## UX Copy Guidelines (no tech jargon)
| Technical Term | User-Facing Copy |
|---|---|
| VRAM | graphics memory |
| quantization | compressed model |
| out-of-core | runs from disk (slower) |
| smart memory management | Studiomc makes it work on your hardware |
| KV-cache | (never shown) |
| sharding | (never shown) |
| inference backend | (never shown — just show backend badge) |
| frontier API | cloud model |

Examples:
- "This model is compressed to run on your machine."
- "Your drive is limiting speed. An NVMe SSD will feel faster."
- "Studiomc's smart memory lets you run larger models than your hardware usually supports."
- Always provide a recommended alternative.

## Document Chat UX
- User uploads docs → UI shows: "Preparing knowledge (2–5 min)" with progress → "Ask your documents"
- No "build index" jargon, no settings screens
- Answers show sources (in Docs/Investigate mode)
- Quality toggle: Fast answers (latent-only) / Cited answers (latent + snippets) / Deep research (latent + iterative retrieval)
- Smart memory note: "Document queries use compressed retrieval — larger models handle docs efficiently on your hardware"
