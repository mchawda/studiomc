# Product Roadmap

## Sections

### 1. Onboarding
Welcome screen, automatic hardware scan (GPU/VRAM, RAM, disk speed benchmark), auto model recommendation + download with pause/resume/checksum, first chat. The "magic moment" — install to productive in under 2 minutes. No choices, no jargon. See `ux-spec.md` for full onboarding flow.

### 2. Chat
Sidebar conversation list (grouped by today/yesterday/older), streaming chat via WebSocket, prompt presets (Default/Writing/Coding/Tutor), regenerate/edit/branch (via parent_message_id), conversation controls (rename, pin, export Markdown), memory toggle, attach file, mode switch (Chat/Docs/Investigate). See `ux-spec.md` for chat requirements.

### 3. Models
Unified model library across all backends. Auto-detects Ollama (`localhost:11434`) and LM Studio (`localhost:1234`) on startup. Built-in AirLLM engine with out-of-core inference for smart memory management. Optional frontier API support (OpenAI, Anthropic, Google, Mistral, custom OpenAI-compatible). App recommends the best model across ALL available backends via Autopilot. Backend shown as badge ("Local via Ollama", "Cloud via OpenAI"). Local always preferred over cloud. Cloud requests require explicit privacy consent. UX guardrails for oversized models explain smart memory management ("Studiomc can run this using disk streaming"). Manual import via HF ID, Ollama model name, or local path in advanced settings only. See `performance-engineering.md` for recommendation algorithm and smart memory management.

### 4. Documents
Document library, collections (folders), upload PDF/TXT/MD. CLaRa compression-native ingestion (background with "Preparing knowledge" progress). Three user modes: Fast answers (latent-only), Cited answers (latent + text snippets), Deep research (latent + iterative retrieval). Groundedness meter (% supported, source list, "no source" banner). Storage: docs/<doc_id>/original, extracted.txt, chunks.jsonl; indexes/<collection_id>/vectors.

### 5. Investigate (LRE)
Local Reasoning Environment — sandboxed tool runtime (NOT a general shell). Safe tools: search(query, scope), grep(pattern, files), open(doc_id, span), summarize(doc_id, span), table_extract(doc_id, span), cite(doc_id, span). Recursive Orchestrator with RLM-style loop: plan → tool → observe → answer/sub-query. Budgets: 6 tool calls, depth 2, 8k tokens, 20s wall-clock. Explainable trace panel. "I can't find this" honesty. See `security-and-licensing.md` for LRE security model.

### 6. Performance Dashboard
Speed Rating (Fast/OK/Slow/Painful) derived from tok/s + TTFT + disk saturation. TTFT, tok/s, RAM/VRAM usage, disk throughput, model load time. Performance Tuner auto-adjusts context length, batch size, prefetch depth, threading. User-friendly — no technical metrics unless advanced mode. See `performance-engineering.md` for P0/P1/P2 phases.

### 7. Settings
Privacy settings, theme selection (two recommended defaults + user custom), advanced toggle revealing: model import (HF/Ollama/local), model backends (Ollama status, LM Studio status, AirLLM status, cloud provider API keys with encrypted storage, local API toggle), performance tuning, diagnostics (benchmarks, logs, system status), support bundle export (one-click, sanitized, never includes chat content), About → Open Source Licenses (THIRD_PARTY_NOTICES, license texts, NOTICE file). See `security-and-licensing.md` for compliance requirements.

## Build Order
1. Onboarding → 2. Chat → 3. Models → 4. Performance Dashboard → 5. Documents → 6. Investigate → 7. Settings

## Release Phases

### Phase 1 — "ChatGPT-like local chat"
Sections: Onboarding, Chat, Models, Performance Dashboard, Settings (basic), Local API
- Desktop installer + onboarding + auto-recommended model
- **Multi-backend support**: auto-detect Ollama + LM Studio, built-in AirLLM engine
- Chat UI with history, presets, branching
- Unified model library across all local backends
- Model manager (download/verify/resume + Ollama pull)
- **Smart memory management** (AirLLM out-of-core) with honest speed predictions
- Performance dashboard + speed rating
- Local OpenAI-compatible endpoint
- **Frontier API support** (advanced): add OpenAI/Anthropic/Google/Mistral keys, cloud consent flow

### Phase 2 — "Documents + trust"
Sections: Documents, CLaRa RAG, Settings (full)
- Document library + CLaRa compression-native ingestion
- **Smart memory for docs**: CLaRa 32-64x compression means bigger models handle docs on less hardware
- Collections + cited answers + groundedness meter
- Search across chats/docs

### Phase 3 — "Advanced performance + deep reasoning"
Sections: Investigate (LRE), Performance (P1/P2)
- Speculative decoding + better context management
- LRE with safe tools + Recursive Orchestrator
- Investigate mode with explainable trace
- CLaRa end-to-end training
- Crash-proof model switching + OOM prevention + auto-fallback

## Related Documents
- `architecture.md` — services, APIs, process model, file layouts
- `ux-spec.md` — onboarding flow, chat spec, guardrails, copy guidelines
- `performance-engineering.md` — P0/P1/P2 phases, algorithms, acceptance criteria
- `security-and-licensing.md` — threat model, compliance, engineering risks
