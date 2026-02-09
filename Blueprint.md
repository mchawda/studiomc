# studiomc Desktop — Technical [Blueprintv1.md]
(**Product goal:** A mass-market, “ChatGPT-easy” desktop app that runs open local models with maximum usability, privacy, and predictable performance—built on AirLLM’s out-of-core capabilities, while being brutally honest about hardware limits. Our product is called “Studiomc”.

> **Non-negotiable truth:** “70B on 4GB” is a *capability demo*, not a *pleasant experience*. The product wins by making the *right* model feel great on each machine and by keeping “too-big” models usable through guardrails, smart defaults, and transparent expectations.

---

## 0) Product Principles
### 0.1 UX principles (what users must feel)
1. **Instant gratification:** User sees a working chat in under 2 minutes from install.
2. **No jargon:** Users never need to understand VRAM, quantization, KV-cache, sharding.
3. **Performance honesty:** The product predicts experience and explains constraints in plain English.
4. **Safety by default:** Local privacy + clear boundaries. No hidden network calls.
5. **Progressive power:** Basic users get “ChatGPT-like.” Advanced users can tune.

### 0.2 Experience targets (acceptance criteria)
- **Install to first message:** ≤ 2 minutes on a typical consumer machine (excluding model download).
- **First token latency (TTFT):**
  - Recommended models: **≤ 2.5s** typical
  - “Large but allowed” models: **≤ 8s** typical with warnings
- **Tokens/sec (steady state):**
  - Recommended: **≥ 10 tok/s** on mid-range GPU (or ≥ 4 tok/s CPU-only depending on model)
- **Crashes:** 0 during normal usage paths; safe recovery with clear message if a model fails.
- **Model download reliability:** resumable, checksum verified, low support burden.

---

## 1) Who This Is For
### 1.1 User segments
1. **Everyday users:** Want a private ChatGPT-like assistant for writing, learning, brainstorming.
2. **Professionals:** Want local notes + document chat + policy-safe workflows.
3. **Power users:** Want any model, parameter control, custom system prompts, local endpoints.

### 1.2 Primary use cases (MVP)
- Chat with a local model (fast + stable)
- Import text/PDF and ask questions (basic RAG-lite)
- “Personal workspace” with chat history + folders
- Optional local OpenAI-compatible API endpoint for integrations

---

## 2) Scope Boundaries (what we will NOT promise)
- No promise that **70B on 4GB VRAM** is “smooth.” We will allow it only behind:
  - Experience warnings
  - “Slow mode”
  - Benchmarked estimate
  - Explicit user acknowledgement (once)
- No “agent that hacks systems,” no exploit tooling.
- No hidden telemetry. Opt-in only.

---

## 3) Product Definition
### 3.1 Core features
1. **One-click install** (Windows/macOS/Linux)
2. **Hardware scan + smart recommendations**
3. **Model library**:
   - Browse curated list (“Works best on your machine”)
   - Add any local model path
   - Add Hugging Face model via ID
4. **Chat UI**:
   - Streaming responses
   - Chat history + search
   - Prompt presets (Default / Writing / Coding / Tutor)
   - Regenerate + Edit + Branch conversation
5. **Document chat (MVP)**:
   - Upload PDF/TXT/MD
   - Basic extraction + chunking
   - Simple retrieval with citations (local)
6. **Performance dashboard (user-friendly)**:
   - “Speed rating”: Fast / OK / Slow
   - TTFT, tok/s, RAM/VRAM usage, disk throughput
7. **Local server mode (optional)**:
   - OpenAI-compatible endpoint
   - API key locally stored

### 3.2 Differentiators (why users choose this)
- **The “Right Model” autopilot:** pick best model automatically for your machine and task.
- **Transparent performance & cost:** no confusion, no disappointment.
- **Best-in-class local UX:** feels like ChatGPT, not a GitHub project.

---

## 4) UX/UI Specification (ChatGPT-easy)
### 4.1 Information architecture
- **Home**
  - “New Chat”
  - Recent chats
  - Quick actions: Upload doc, Add model, Settings
- **Chat**
  - Conversation list (left)
  - Chat stream (center)
  - Context panel (right): model, mode, doc sources, speed rating
- **Models**
  - Recommended (top)
  - Installed
  - Discover (curated)
  - Import (HF ID / local file)
- **Documents**
  - Library
  - Collections (folders)
  - “Chat with this document”
- **Settings**
  - Privacy
  - Performance
  - Advanced (hidden behind toggle)
- **Diagnostics**
  - Benchmarks
  - Logs (export button)
  - System status

### 4.2 Onboarding flow (critical)
#### Step 1: Welcome
- “Local AI. Private by default.”
- Buttons: **Get Started** | **I already have a model**

#### Step 2: Hardware scan (automatic)
Displays:
- GPU / VRAM detected (or CPU-only)
- RAM
- Disk type (NVMe/SATA/Unknown) + measured read speed quick test

#### Step 3: Recommendation (the product’s “magic moment”)
- “Best experience for you” (1–3 models)
- “Bigger models (slower)” (collapsed)
- Plain-English explanation:
  - “This model will feel responsive.”
  - “This one will be slower due to disk streaming.”

#### Step 4: Download & verify
- Progress, ETA, resumable
- “Pause / resume”
- “Verify integrity” (checksum)

#### Step 5: First chat
- Starts with a helpful system prompt:
  - “You are a private local assistant. Ask me anything.”

### 4.3 Chat experience requirements
- **Input box** with:
  - Attach file
  - Mode switch (Writing/Coding/Tutor)
  - “Memory toggle” (local memory summary per workspace; user controlled)
- **Output**:
  - Streaming tokens
  - Copy, regenerate, “continue”
  - “Explain sources” for doc answers
- **Conversation controls**:
  - Rename
  - Pin
  - Export (Markdown)

### 4.4 UX guardrails for huge models (“70B on 4GB”)
When user selects model predicted “Painful”:
- Show a single modal:
  - “This will be slow on your hardware (estimated 0.3–1.2 tok/s).”
  - “Recommended alternative: X (fast).”
  - Buttons: **Use recommended** | **Run anyway**
- If “Run anyway”, app auto-sets:
  - Lower context length
  - Conservative batch sizes
  - Aggressive prefetch
  - “Slow mode” UI indicator

---

## 5) System Architecture Overview
### 5.1 High-level components
1. **Desktop App (UI Shell)**  
   - Tauri (Rust + WebView) or Electron (if speed of delivery is priority)
2. **Local Inference Service**
   - AirLLM-based Python service for model execution
3. **Model Manager Service**
   - Download, verify, cache, metadata, quant selection
4. **Document Pipeline**
   - Local extraction + chunking + embeddings + retrieval
5. **Storage Layer**
   - SQLite + filesystem
6. **Telemetry (Opt-in)**
   - Local metrics always; remote only with explicit consent

### 5.2 Process model
- UI launches a **Local Supervisor** (Rust)
- Supervisor starts:
  - `inference-service` (Python)
  - `model-manager`
  - `doc-service`
- UI communicates via:
  - HTTP/WebSocket to local services on `127.0.0.1`

### 5.3 Deployment model
- Fully offline capable
- No cloud dependency
- Optional: “Remote API integrations” disabled by default

---

## 6) Technology Stack (recommended)
### 6.1 Desktop
- **Tauri (Rust)** + React/Vue/Svelte UI
- Advantages:
  - Small installer footprint
  - Native OS integration
  - Strong security model

### 6.2 Services
- Python 3.11+ (embedded runtime)
- FastAPI + WebSockets for streaming chat
- AirLLM as inference engine

### 6.3 Storage
- SQLite for metadata + chat history + doc index state
- File system for:
  - model blobs
  - extracted text
  - embeddings index files

### 6.4 Embeddings (MVP)
- Local embeddings model (small)
- Pluggable provider interface (allow swap later)

---

## 7) Performance Engineering Plan (without lying)
### 7.1 Reality: where performance dies
- Disk I/O stalls
- CPU<->GPU transfer overhead
- KV-cache growth for long chats
- Model format fragmentation

### 7.2 Performance roadmap (phased)
#### Phase P0: “Feels good on recommended models”
- Deep async prefetch pipeline
- Hot layer residency:
  - embeddings
  - first N layers
  - last N layers
- Memory mapping option:
  - `mmap` weights to leverage OS page cache
- A “Performance Tuner” that auto-adjusts:
  - context length
  - batch size
  - prefetch depth
  - threading

#### Phase P1: “Make large models less awful”
- Speculative decoding (draft model resident)
- Better KV cache policy:
  - truncation controls
  - per-chat context summaries
- Smart “context manager”:
  - compress history automatically (optional, local)

#### Phase P2: “Mass stability”
- Crash-proof model switching
- Preflight checks to avoid OOM
- Automatic fallback to smaller model when necessary

---

## 8) Model Management (the core of usability)
### 8.1 Supported inputs
- Hugging Face model ID (download)
- Local directory path
- Pre-quantized formats (if supported by AirLLM build)

### 8.2 Model registry metadata
Each model record:
- model_id, name, source (hf/local)
- architecture family
- parameter count
- quantization type
- disk size
- recommended RAM/VRAM
- supported context sizes
- checksum + file manifest
- last used timestamp

### 8.3 Recommendation engine (“Autopilot”)
Inputs:
- VRAM, RAM, disk speed (measured), CPU
- User intent: chat, documents, coding
- Latency targets

Outputs:
- A ranked list with predicted:
  - TTFT
  - tok/s
  - “speed rating” label

Heuristic rules (MVP):
- Avoid models predicted < 1 tok/s unless user insists
- Prefer smaller models with better responsiveness
- Prefer quantized variants when constrained

---

## 9) Document Chat (RAG-lite MVP)
### 9.1 User flow
- Upload doc(s) -> choose collection -> “Chat with collection”
- Answers include citations (filename + chunk id)

### 9.2 Pipeline (local)
1. Extract text
2. Normalize
3. Chunk (e.g., 500–1000 tokens)
4. Embed chunks
5. Store vectors locally
6. Retrieve top-k chunks on query
7. Compose prompt with citations

### 9.3 Storage layout
- `docs/<doc_id>/original.*`
- `docs/<doc_id>/extracted.txt`
- `docs/<doc_id>/chunks.jsonl`
- `indexes/<collection_id>/vectors.*`

---

## 10) Data Model (SQLite Schema)
```sql
-- core app state
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE models (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  source TEXT NOT NULL, -- 'hf' | 'local'
  source_ref TEXT,      -- hf_id or local path
  params_billion REAL,
  quant TEXT,
  disk_bytes INTEGER,
  arch TEXT,
  context_max INTEGER,
  checksum TEXT,
  manifest_json TEXT,
  created_at TEXT,
  last_used_at TEXT
);

CREATE TABLE benchmarks (
  id TEXT PRIMARY KEY,
  model_id TEXT,
  hw_fingerprint TEXT,
  disk_read_mbps REAL,
  ttft_ms INTEGER,
  tok_per_s REAL,
  notes TEXT,
  created_at TEXT,
  FOREIGN KEY(model_id) REFERENCES models(id)
);

CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  title TEXT,
  model_id TEXT,
  mode TEXT, -- default|writing|coding|tutor
  created_at TEXT,
  updated_at TEXT,
  FOREIGN KEY(model_id) REFERENCES models(id)
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  role TEXT NOT NULL, -- system|user|assistant|tool
  content TEXT NOT NULL,
  tokens INTEGER,
  created_at TEXT,
  parent_message_id TEXT,
  FOREIGN KEY(chat_id) REFERENCES chats(id)
);

CREATE TABLE documents (
  id TEXT PRIMARY KEY,
  filename TEXT,
  mime TEXT,
  bytes INTEGER,
  sha256 TEXT,
  created_at TEXT
);

CREATE TABLE collections (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT
);

CREATE TABLE collection_documents (
  collection_id TEXT,
  document_id TEXT,
  PRIMARY KEY(collection_id, document_id),
  FOREIGN KEY(collection_id) REFERENCES collections(id),
  FOREIGN KEY(document_id) REFERENCES documents(id)
);

CREATE TABLE doc_chunks (
  id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL,
  chunk_index INTEGER,
  text TEXT,
  token_count INTEGER,
  metadata_json TEXT,
  FOREIGN KEY(document_id) REFERENCES documents(id)
);

CREATE TABLE vector_indexes (
  id TEXT PRIMARY KEY,
  collection_id TEXT NOT NULL,
  embed_model TEXT NOT NULL,
  dims INTEGER NOT NULL,
  path TEXT NOT NULL,
  created_at TEXT,
  FOREIGN KEY(collection_id) REFERENCES collections(id)
);



11) Local APIs (UI ↔ Services)

11.1 Inference service
	•	POST /v1/chat/completions (OpenAI-compatible)
	•	WS /v1/chat/stream (UI streaming)
	•	GET /v1/models (installed models)
	•	POST /v1/models/select (set active model for a chat)

Request extensions (internal):
	•	x-airllm-profile: fast|balanced|quality
	•	x-airllm-slowmode: true|false

11.2 Model manager
	•	POST /models/add (HF ID or local path)
	•	GET /models/status/{id}
	•	POST /models/download/{id}/pause
	•	POST /models/download/{id}/resume
	•	DELETE /models/{id}
	•	POST /models/verify/{id}

11.3 Documents
	•	POST /docs/upload
	•	POST /docs/extract/{doc_id}
	•	POST /collections/create
	•	POST /collections/{id}/add-doc
	•	POST /collections/{id}/build-index
	•	POST /collections/{id}/query

⸻

12) Observability & Diagnostics (UX-grade)

12.1 Always local metrics
	•	TTFT, tok/s per chat
	•	RAM/VRAM usage snapshots
	•	Disk throughput during generation
	•	Cache hit ratio (if applicable)
	•	Model load time
	•	OOM or fallback events

12.2 User-facing “Speed Rating”

Derived from:
	•	tok/s
	•	TTFT
	•	disk saturation

Labels:
	•	Fast: responsive
	•	OK: usable
	•	Slow: noticeable lag, suggest smaller model
	•	Painful: user must opt in

12.3 Support bundle export
	•	One-click “Export diagnostics”
	•	Includes:
	•	logs (sanitized)
	•	benchmark results
	•	model metadata
	•	crash dumps (if any)
	•	Never includes chat content unless user explicitly chooses.

⸻

13) Security & Privacy

13.1 Local-first security model
	•	Services bind to 127.0.0.1 only by default
	•	API keys stored encrypted (OS keychain if available)
	•	Model downloads verified via checksum/manifest
	•	No remote telemetry unless opt-in

13.2 Threat model (practical)
	•	Protect against:
	•	local malware scraping files (best effort: encryption at rest for keys only)
	•	malicious model files (sandbox + checksum + allowlist for curated downloads)
	•	prompt injection via documents (RAG sanitizer + source display)

⸻

14) File/Folder Layout (Repo + Runtime)

14.1 Repo layout
```
studiomc-desktop/
  apps/
    desktop-ui/            # Tauri UI (React)
    supervisor/            # Rust process supervisor
  services/
    inference/             # FastAPI + studiomc integration
    model_manager/         # downloads, verification, registry
    documents/             # extraction + chunk + embed + retrieval
  packages/
    common/                # shared types, schemas, protocols
  scripts/
    build/
    release/
  docs/

    

```

14.2 Runtime layout (user machine)
```
~/.studiomc-desktop/
  db/app.sqlite
  models/
    <model_id>/
      blobs/...

      

  docs/
    <doc_id>/...
  indexes/
    <collection_id>/...
  logs/
    app.log
    inference.log
    model_manager.log
  cache/
    downloads/
```

15) Critical Algorithms (MVP versions)

15.1 Hardware scan + benchmark
	•	Quick disk test:
	•	sequential read of ~512MB temp file
	•	Quick inference micro-bench:
	•	load minimal model or selected model
	•	measure TTFT + tok/s for 32 tokens
	•	Store results keyed by hw_fingerprint

15.2 Recommendation heuristic (MVP)

Pseudo:
	1.	Filter models by memory feasibility
	2.	Score by:
	•	predicted tok/s (from benchmarks or heuristic)
	•	model quality tier (params, known family)
	•	use case fit (coding vs chat)
	3.	Apply penalties:
	•	disk too slow
	•	CPU-only large model
	4.	Return top 3 + “bigger slower” list

⸻

16) UX Copy Guidelines (no tech jargon)
	•	Replace “VRAM” with “graphics memory”
	•	Replace “quantization” with “compressed model”
	•	Replace “out-of-core” with “runs from disk (slower)”
	•	Always provide a recommended alternative

Examples:
	•	“This model is compressed to run on your machine.”
	•	“Your drive is limiting speed. An NVMe SSD will feel faster.”

⸻

17) Release Plan

Phase 1 (MVP) — “ChatGPT-like local chat”
	•	Desktop installer + onboarding + recommended model
	•	Chat UI with history
	•	Model manager (download/verify)
	•	Performance dashboard
	•	Local-only endpoint

Phase 2 — “Documents + trust”
	•	Document library + RAG-lite with citations
	•	Collections
	•	Search across chats/docs

Phase 3 — “Advanced performance”
	•	Speculative decoding
	•	Better context management (auto summaries)
	•	More stable big-model experience modes

⸻

18) Engineering Risks (and mitigation)
	1.	Python packaging hell
	•	Mitigation: embed runtime, pin deps, ship wheels, minimize native compilation on user machine
	2.	User disappointment from slow models
	•	Mitigation: recommendation engine + warnings + speed rating + hard defaults
	3.	Model format fragmentation
	•	Mitigation: curated list + import support + background verification
	4.	Support burden
	•	Mitigation: diagnostics export + deterministic installers + strong defaults

⸻

19) Architecture Diagram (Mermaid)

```
flowchart LR
  UI[Tauri Desktop UI] -->|HTTP/WS localhost| SUP[Supervisor (Rust)]
  SUP --> INF[Inference Service (FastAPI + studiomc)]
  SUP --> MM[Model Manager Service]
  SUP --> DOC[Document Service]
  INF --> DB[(SQLite)]
  MM --> DB
  DOC --> DB
  MM --> FS[(Models on Disk)]
  DOC --> FS2[(Docs/Indexes on Disk)]
```

20) What “Success” Looks Like
	•	Users install and chat without reading documentation.
	•	Users choose the recommended model and feel it’s “fast enough”.
	•	Power users can load any model, but the system prevents self-inflicted pain.
	•	The product feels like ChatGPT, but private, local, and transparent.

⸻

21) Immediate Next Actions (execution order)
	1.	Build Supervisor + Inference service with streaming chat
	2.	Build Onboarding + Hardware scan + Recommendation
	3.	Implement Model Manager (download/verify/resume)
	4.	Ship Chat UI (history, presets, regenerate)
	5.	Add Performance dashboard + speed rating
	6.	Add Docs pipeline (RAG-lite) after core chat is stable
	

# Addendum: CLaRa-Enhanced RAG (Compression-Native, UX-First)

## A) Why CLaRa improves real-world RAG
Traditional RAG is a glue job:
- Retriever optimizes embedding similarity
- Generator optimizes language modeling
- No shared objective → mismatched evidence selection → long “token salads” and hallucinations

**CLaRa changes the unit of retrieval from “text chunks” to “compressed latent representations”**
and trains retrieval + generation end-to-end (single LM loss), enabling:
- **Large compression (reported 32x–64x in repo; paper discusses large context reduction)**  
- **Differentiable top-k selection so gradients can update retriever + generator together**  
- Better alignment between “what is retrieved” and “what improves the final answer”  
 [oai_citation:1‡arXiv](https://arxiv.org/abs/2511.18659?utm_source=chatgpt.com)

## B) What we add to studiomc Desktop: CLaRaRAG Engine
### B.1 Goals (product requirements)
- Make document-chat feel fast and reliable on consumer hardware
- Reduce context stuffing (less latency, less cost, fewer failures)
- Improve multi-hop QA (questions requiring multiple parts of a doc set)
- Provide citations (trust UX)

### B.2 New components
1) **Compressor (CLaRa compressor)**
   - Input: document text / chunk text
   - Output: compressed latent vectors (“memory tokens”)
   - Stored in local vector store

2) **Latent Retriever / Reranker**
   - Retrieves top-k compressed vectors relevant to query
   - Optionally reranks in latent space

3) **Generator (CLaRa generator or adapter)**
   - Consumes retrieved latent vectors, not full raw text
   - Produces answer
   - Can optionally request “text reveal” for citations

### B.3 Two-tier evidence: Latent-first, Text-on-demand
To preserve citations while keeping context tiny:
- Default pipeline: retrieve latent vectors → generate answer
- Citation pipeline: map latent vectors to source spans:
  - store chunk->source mapping during preprocessing
  - optionally retrieve minimal text snippets for quoting and citations

This gives:
- Speed + quality (latent)
- Trust (minimal text)

## C) User Experience upgrades (this is the point)
### C.1 “Docs just work” UX
Replace “build index” jargon with:
- User uploads docs
- UI shows: “Preparing knowledge (2–5 min)” with progress
- Then: “Ask your documents”

### C.2 Quality controls that users understand
Add a simple toggle in the chat sidebar:
- **Fast answers** (latent-only)
- **Cited answers** (latent + minimal text snippets)
- **Deep research** (latent + iterative retrieval + more snippets)

### C.3 Reliability indicators
Show “Groundedness meter” (not fake certainty):
- % of answer supported by retrieved sources
- list of sources used
- “No source found” banner when appropriate

### C.4 Massive UX win: Small context = more stable
Consumers hate “it forgot the doc” or “it got slow”.
CLaRa reduces context length pressure, improving:
- time-to-first-token
- fewer truncation failures
- less RAM pressure
 [oai_citation:2‡arXiv](https://arxiv.org/abs/2511.18659?utm_source=chatgpt.com)

## D) Implementation Plan (practical path)
### D.1 MVP: Use CLaRa as a preprocessing + retrieval layer
Phase 1 (fastest):
- Use CLaRa compressor to create compressed vectors for chunks
- Use standard generator (your local model) with prompt containing:
  - top-k compressed vectors (serialized)
  - optional minimal text snippets for citations
- This avoids full end-to-end fine-tuning initially.

Phase 2 (better):
- Adopt CLaRa end-to-end training approach:
  - compression pretraining
  - compression instruction tuning
  - end-to-end fine-tuning
(as per the official repo’s staged approach)  [oai_citation:3‡GitHub](https://github.com/apple/ml-clara?utm_source=chatgpt.com)

Phase 3 (product-grade):
- Differentiable retrieval training loop integrated for your target domain corpora
- Domain-specific SCP-like synthesis (QA + paraphrase supervision) for better compression retention  [oai_citation:4‡arXiv](https://arxiv.org/abs/2511.18659?utm_source=chatgpt.com)

## E) Data Model additions
Add tables:
- clara_vectors(doc_chunk_id, vector_blob, dims, compressor_version, created_at)
- clara_mappings(doc_chunk_id, source_offsets_json, sha256)
- clara_indexes(collection_id, path, dims, created_at)
- clara_runs(chat_id, mode, top_k, cited_mode, metrics_json)

## F) Local APIs (new)
- POST /clara/ingest (docs -> chunks -> latent vectors)
- GET /clara/ingest/status/{job_id}
- POST /clara/query (query -> top-k latent vectors + optional snippet retrieval)
- POST /clara/answer (query + vectors -> answer + citations)

## G) Performance & UX acceptance criteria (Doc Chat)
- Latent-only answers:
  - TTFT ≤ 2.5s on recommended model + local store
  - Retrieval p95 ≤ 150ms for top-k=8 (local)
- Cited answers:
  - TTFT ≤ 4.5s (because snippet fetch)
  - citations always shown (or “no sources”)

## H) Risks (be honest)
1) **CLaRa end-to-end training is non-trivial**
   - Mitigation: ship MVP with CLaRa compression first, train later.
2) **Citations require text mapping**
   - Mitigation: minimal text-on-demand layer.
3) **Model compatibility / licensing**
   - Mitigation: keep CLaRa modules optional, pluggable, and local.
   

## Licensing & Compliance (Apache 2.0 and Mixed OSS)

### Compliance objectives
- Ship a commercial desktop app while fully complying with Apache 2.0 obligations for any included components.
- Maintain a complete and auditable third-party notice trail inside the installer and inside the app UI.

### Required artifacts (must be shipped)
- `/THIRD_PARTY_NOTICES.md` (top-level): inventory of all third-party components with license type and source.
- `/LICENSES/` directory:
  - `APACHE-2.0.txt` (full license text)
  - Additional license texts for all bundled dependencies
- `/NOTICE` file:
  - Includes upstream NOTICE contents verbatim where required (Apache 2.0 §4(d))
  - Our addendum appended below upstream notices

### In-app disclosure (must exist)
- Settings → About → “Open Source Licenses”
  - Displays THIRD_PARTY_NOTICES
  - Displays full license texts
  - Displays NOTICE file
- Installer includes a “Third-party licenses” link

### Engineering rules
- Any modified Apache-derived file must contain a header:
  - “Modified by <Company> on <YYYY-MM-DD>”
  - Brief description of modifications
- CI blocks merges if:
  - a dependency is introduced without license metadata
  - NOTICE obligations are not satisfied
  - license texts are missing from `/LICENSES`

### Release checklist
- Run OSS license scan (ScanCode/FOSSA or equivalent)
- Generate THIRD_PARTY_NOTICES + LICENSES bundle
- Verify NOTICE propagation requirements
- Confirm product branding does not imply upstream endorsement

# Addendum: RecursiveLM + CLaRaRAG for “ChatGPT-easy” Local Intelligence

## A) Problem: RAG UX fails when users have real documents
Baseline RAG has three mass-market failure modes:
1) “It’s slow” (context stuffing + long prompts)
2) “It’s wrong” (retriever/generator mismatch, irrelevant chunks)
3) “I don’t trust it” (weak citations, hidden reasoning)

We solve this by combining:
- **CLaRaRAG** = compression-native retrieval (latent-first, text-on-demand)
- **RecursiveLM (RLM-style REPL)** = a controlled “tools environment” where the model can inspect, decompose, grep, and recursively query the corpus instead of stuffing it into context

RLMs treat long prompts/corpora as an external environment and let the LM programmatically examine and recursively call itself over snippets.  [oai_citation:1‡arXiv](https://arxiv.org/abs/2512.24601?utm_source=chatgpt.com)

---

## B) Product behavior: what users experience (UX-first)
### B.1 New user-facing modes (simple, understandable)
In the chat sidebar (one control, no jargon):
- **Chat (Fast)**: normal chat, minimal retrieval
- **Docs (Cited)**: answers with citations, best default for documents
- **Investigate (Deep)**: slower but thorough; model uses tools (grep/slice/table) and can run recursive sub-queries

### B.2 What makes it feel like ChatGPT (but local)
- **No “index settings” screens**. Ingestion runs in background with progress.
- **Answers show sources** (when in Docs/Investigate mode).
- **The assistant can “look up” inside files** rather than hallucinating.

### B.3 The critical UX rule
If the system cannot find evidence, it must say:
> “I can’t find this in your documents. Want me to broaden the search or check another folder?”

No fake confidence.

---

## C) Architecture: add a “Local Reasoning Environment” (LRE)
### C.1 New components
1) **Local Reasoning Environment (LRE) Service**
   - A sandboxed REPL-like tool runtime (NOT a general shell)
   - Exposes a curated set of “safe tools”:
     - `search(query, scope)`
     - `grep(pattern, files)`
     - `open(doc_id, span)`
     - `summarize(doc_id, span)`
     - `table_extract(doc_id, span)` (MVP: regex + heuristics)
     - `cite(doc_id, span)` (returns source citation object)
   - Stores “context” as structured objects rather than prompt text

2) **Recursive Orchestrator**
   - Implements RLM-style loop: plan → tool → observe → (optional sub-call) → answer
   - Enforces budgets:
     - max tool calls
     - max recursion depth
     - max tokens
     - timeouts

3) **CLaRaRAG Engine (optional but recommended default for Docs mode)**
   - Latent compression store + retrieval
   - Text-on-demand for citations

RLM paradigm reference: replace `llm.completion(prompt)` with `rlm.completion(prompt)` where the prompt becomes an environment variable the model can programmatically inspect.  [oai_citation:2‡GitHub](https://github.com/alexzhang13/rlm?utm_source=chatgpt.com)

### C.2 Updated system diagram
```mermaid
flowchart LR
  UI[Tauri Desktop UI] -->|HTTP/WS localhost| SUP[Supervisor (Rust)]
  SUP --> INF[Inference Service (studiomc)]
  SUP --> MM[Model Manager]
  SUP --> DOC[Document Service]
  SUP --> CLARA[CLaRaRAG Service]
  SUP --> LRE[Local Reasoning Environment]
  INF --> ORCH[Recursive Orchestrator]
  ORCH --> LRE
  ORCH --> CLARA
  DOC --> CLARA
  ORCH --> UI
  
  D) RecursiveLM behavior (RLM-style) inside the product

D.1 Control loop (deterministic, debuggable)

The assistant runs a bounded loop:
	1.	Plan: decide whether it needs tools
	2.	Act: call one tool
	3.	Observe: store results as structured memory
	4.	Decide:
	•	answer now, or
	•	issue a sub-query (recursive LM call) over a specific slice of context

This is aligned with the RLM paper’s strategy for scaling effective context beyond the model window.  ￼

D.2 Budgets (what keeps it stable for “the masses”)

Default budgets per query:
	•	Tool calls: 6
	•	Recursion depth: 2
	•	Total retrieved text: 8k tokens (hard cap)
	•	Wall-clock: 20s (Investigate mode); 8s (Docs mode)
	•	If exceeded: return best-effort with “I stopped because…” explanation

D.3 Explainable trace (UX differentiator)

In Investigate mode, show a collapsible panel:
	•	“Search: ‘…’ in Folder X”
	•	“Opened: Doc A (p3–p4)”
	•	“Extracted: table rows 12–17”
	•	“Cited: …”

This is how you win trust without dumping internal chain-of-thought.

⸻

E) CLaRaRAG + RecursiveLM: how they combine (best of both)

E.1 Fast path (Docs mode)
	•	Query → CLaRa latent retrieval (top-k latent vectors)
	•	Generator answers from latents
	•	Fetch minimal text snippets only for citations

Result: small prompt, fast, grounded.

E.2 Deep path (Investigate mode)

Recursive Orchestrator can choose:
	•	Use CLaRa for broad “what areas matter”
	•	Then use tools to surgically extract the exact spans for final answer and citations

This avoids the classic RAG failure: irrelevant chunk stuffing.

CLaRa reference: compression-native retrieval to reduce context pressure and improve alignment of retrieval with generation quality.  ￼

⸻

F) APIs to add (UI ↔ Orchestrator/LRE)

F.1 Orchestrator endpoints
	•	POST /reasoning/run
	•	input: chat_id, user_query, mode (fast|cited|investigate), budgets
	•	output: answer, citations[], trace[]

F.2 LRE tool endpoints (internal only)
	•	POST /lre/search
	•	POST /lre/grep
	•	POST /lre/open
	•	POST /lre/summarize
	•	POST /lre/table_extract

F.3 Data model additions (SQLite)

CREATE TABLE reasoning_runs (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  mode TEXT NOT NULL, -- fast|cited|investigate
  budgets_json TEXT NOT NULL,
  trace_json TEXT,
  citations_json TEXT,
  metrics_json TEXT,
  created_at TEXT
);

G) Security model (critical for a REPL-like system)

G.1 Hard rule: No unrestricted shell

The LRE is NOT a general OS REPL.
	•	No bash, no file writes outside app sandbox
	•	Read-only access to user-approved folders
	•	Allowlist of operations with strict parameter validation

G.2 Permission UX (mass-friendly)

First time user adds a folder:
	•	OS-native permission prompt (where possible)
	•	“This app can read these folders only”
	•	Clear revoke option in Settings

⸻

H) Performance impact and why this improves usability

H.1 Why it feels faster
	•	Less prompt stuffing
	•	Smaller context windows per step
	•	Tools do cheap local search instead of model attention over everything
	•	Recursive calls are scoped to small spans

RLMs report handling contexts far beyond base windows by treating prompts as an environment and recursively processing snippets.  ￼

⸻

I) MVP implementation plan (doable, not fantasy)

Phase 1 (Ship value fast)
	•	Implement LRE with safe tools: search/grep/open/summarize/cite
	•	Implement Recursive Orchestrator with budgets + trace
	•	Integrate with existing Document Service (text chunks)
	•	Provide “Investigate mode” UI panel

Phase 2 (Make Docs mode excellent)
	•	Add CLaRa latent store + retrieval
	•	Implement text-on-demand citations mapping
	•	Add “Cited answers” default for documents

Phase 3 (Make it robust at scale)
	•	Better table extraction
	•	Multi-collection routing
	•	Caching: query → retrieved spans → stable citations
	•	Regression suite for groundedness + hallucination rate

⸻

---

## The blunt advice
If you ship **studiomc Desktop + basic RAG**, you’ll get “cool demo” feedback and then churn.  
If you ship **studiomc Desktop + (CLaRa for fast cited doc chat) + (RecursiveLM for deep investigate)**, you’re building a *product* that normal people can trust and use daily.

If you want, I’ll now **merge this addendum into your full blueprint** as a clean v2 (single coherent document), including:
- exact UI screens for the three modes,
- the tool allowlist + parameter schema,
- budgets and fallbacks,
- and a test plan for “groundedness” and “UX latency.”
  
