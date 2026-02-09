# System Architecture

## High-Level Components
1. **Flutter App (UI Shell)** — Cross-platform UI (macOS, Windows, iOS, Android)
2. **Local Supervisor** — Process manager that starts/monitors all services
3. **Inference Router** — Unified gateway that routes to the right backend (Ollama, LM Studio, AirLLM, or frontier APIs)
4. **Inference Service** — FastAPI + AirLLM for out-of-core model execution with smart memory management
5. **Model Manager Service** — Download, verify, cache, metadata, quant selection, backend discovery
6. **Document Service** — Local extraction + chunking + embeddings + retrieval
7. **CLaRaRAG Service** — Compression-native latent retrieval + text-on-demand citations
8. **Local Reasoning Environment (LRE)** — Sandboxed tool runtime for Investigate mode
9. **Recursive Orchestrator** — RLM-style loop: plan → tool → observe → answer
10. **Storage Layer** — SQLite + filesystem
11. **Telemetry (Opt-in)** — Local metrics always; remote only with explicit consent

## Model Backends (inference sources)

Studiomc connects to models through a unified Inference Router. The user doesn't need to understand backends — the app auto-detects and recommends the best path.

### Backend priority (default)
1. **Ollama** (preferred local) — Auto-detected if running. Broadest model support, well-optimized for consumer hardware. App scans `localhost:11434` on startup.
2. **LM Studio** (preferred local) — Auto-detected if running. OpenAI-compatible API on `localhost:1234`. Great for users who already have models loaded.
3. **HuggingFace / AirLLM** (built-in local) — Studiomc's own inference engine. Handles out-of-core execution for running large models on limited hardware via smart memory management. Default for users without Ollama/LM Studio.
4. **Frontier APIs** (cloud, optional) — OpenAI, Anthropic, Google, Mistral, or any OpenAI-compatible endpoint. User adds API key in Settings → Advanced. Clearly labeled as "cloud" with privacy implications shown.

### Auto-detection flow
1. On app launch, Supervisor probes known local endpoints (Ollama, LM Studio)
2. Discovered backends + their loaded models are merged into the unified model list
3. Autopilot recommends the best model across ALL available backends
4. User sees one list — backend shown as a subtle badge ("Local via Ollama", "Local via Studiomc", "Cloud via OpenAI")

### Routing rules
- **Local backends always preferred** over cloud
- If the same model is available via multiple backends, prefer: Ollama > LM Studio > AirLLM
- Frontier APIs used only when: user explicitly selects a cloud model, OR local model cannot handle the task and user has opted in to cloud fallback
- All cloud requests require explicit user consent (first-time modal: "This will send your message to [provider]. Continue?")

## Smart Memory Management (why big models work)

The combination of AirLLM out-of-core inference + CLaRa + RecursiveLM means Studiomc can run models that would normally require far more hardware:

- **AirLLM out-of-core**: Streams model layers from disk through memory, so a 70B model can run on 4GB RAM/VRAM. Disk speed becomes the bottleneck instead of memory.
- **CLaRa compression**: Reduces document context by 32-64x. Instead of stuffing 100k tokens into the prompt, CLaRa retrieves compressed latent vectors. This means the model needs far less working memory per query.
- **RecursiveLM**: Instead of one massive prompt, breaks work into small recursive calls over scoped snippets. Each call uses minimal context, keeping memory pressure low.

**Net effect for users**: A machine that would normally struggle with a 7B model can comfortably run it with documents. A machine that would be "painful" with 70B becomes "slow but usable" with guardrails. The Autopilot factors all of this into its recommendations.

## Process Model
- Flutter app launches the Local Supervisor
- Supervisor starts: inference-service (Python), model-manager, doc-service, clara-service, lre-service
- Supervisor probes for Ollama and LM Studio on known ports
- App communicates via HTTP/WebSocket to local services on 127.0.0.1

## System Diagram
```
Flutter App ──HTTP/WS localhost──▶ Supervisor
                                    ├── Inference Router
                                    │     ├── Ollama (auto-detected, localhost:11434)
                                    │     ├── LM Studio (auto-detected, localhost:1234)
                                    │     ├── AirLLM Engine (built-in, out-of-core)
                                    │     └── Frontier APIs (OpenAI, Anthropic, etc.)
                                    ├── Model Manager
                                    ├── Document Service
                                    ├── CLaRaRAG Service
                                    └── Local Reasoning Environment

Inference Router ──▶ Recursive Orchestrator ──▶ LRE (tools)
                                               ──▶ CLaRaRAG (retrieval)
                                               ──▶ Flutter App (streaming)

Document Service ──▶ CLaRaRAG Service

All services ──▶ SQLite DB
Model Manager ──▶ Models on Disk
Document Service ──▶ Docs/Indexes on Disk
```

## Local APIs

### Inference Router
- `POST /v1/chat/completions` — OpenAI-compatible (routes to active backend)
- `WS /v1/chat/stream` — UI streaming (routes to active backend)
- `GET /v1/models` — merged model list from all backends
- `POST /v1/models/select` — set active model + backend for a chat
- `GET /v1/backends` — list discovered backends and their status
- `POST /v1/backends/probe` — re-scan for local backends (Ollama, LM Studio)
- Request extensions: `x-studiomc-backend: ollama|lmstudio|airllm|frontier`, `x-studiomc-profile: fast|balanced|quality`, `x-studiomc-slowmode: true|false`

### Model Manager
- `POST /models/add` — HF ID, local path, or Ollama model name
- `GET /models/status/{id}`
- `POST /models/download/{id}/pause`
- `POST /models/download/{id}/resume`
- `DELETE /models/{id}`
- `POST /models/verify/{id}`
- `GET /models/backends` — list models per backend

### Documents
- `POST /docs/upload`
- `POST /docs/extract/{doc_id}`
- `POST /collections/create`
- `POST /collections/{id}/add-doc`
- `POST /collections/{id}/build-index`
- `POST /collections/{id}/query`

### CLaRa
- `POST /clara/ingest` — docs → chunks → latent vectors
- `GET /clara/ingest/status/{job_id}`
- `POST /clara/query` — query → top-k latent vectors + optional snippet retrieval
- `POST /clara/answer` — query + vectors → answer + citations

### Orchestrator (Reasoning)
- `POST /reasoning/run` — input: chat_id, user_query, mode (fast|cited|investigate), budgets → output: answer, citations[], trace[]

### LRE Tools (internal only)
- `POST /lre/search`
- `POST /lre/grep`
- `POST /lre/open`
- `POST /lre/summarize`
- `POST /lre/table_extract`

## Repo Layout
```
studiomc/
  lib/                          # Flutter app (Dart)
    screens/
    widgets/
    services/
    models/
  services/
    inference/                  # FastAPI + AirLLM integration
    model_manager/              # downloads, verification, registry
    documents/                  # extraction + chunk + embed + retrieval
    clara/                      # CLaRa compression + retrieval
    lre/                        # Local Reasoning Environment
    orchestrator/               # Recursive Orchestrator
  packages/
    common/                     # shared types, schemas, protocols
  scripts/
    build/
    release/
```

## Runtime Layout (user machine)
```
~/.studiomc/
  db/app.sqlite
  models/
    <model_id>/blobs/...
  docs/
    <doc_id>/original.*
    <doc_id>/extracted.txt
    <doc_id>/chunks.jsonl
  indexes/
    <collection_id>/vectors.*
  logs/
    app.log
    inference.log
    model_manager.log
  cache/
    downloads/
```
