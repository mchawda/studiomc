# Performance Engineering

## Reality: Where Performance Dies
- Disk I/O stalls
- CPU↔GPU transfer overhead
- KV-cache growth for long chats
- Model format fragmentation

## Performance Phases

### Phase P0: "Feels good on recommended models"
- Deep async prefetch pipeline
- Hot layer residency: embeddings, first N layers, last N layers
- Memory mapping option: mmap weights to leverage OS page cache
- Performance Tuner auto-adjusts: context length, batch size, prefetch depth, threading

### Phase P1: "Make large models less awful"
- Speculative decoding (draft model resident)
- Better KV cache policy: truncation controls, per-chat context summaries
- Smart context manager: compress history automatically (optional, local)

### Phase P2: "Mass stability"
- Crash-proof model switching
- Preflight checks to avoid OOM
- Automatic fallback to smaller model when necessary

## Smart Memory Management (why bigger models work)

The combination of three technologies lets Studiomc run models that would normally require far more hardware:

### AirLLM Out-of-Core Inference
- Streams model layers from disk through memory instead of loading the full model
- A 70B model can run on 4GB RAM/VRAM — disk speed becomes the bottleneck, not memory
- Performance Tuner auto-adjusts prefetch depth, batch size, and layer residency based on measured disk speed
- NVMe SSDs give 3-5x better experience than SATA — the app measures this and adjusts recommendations

### CLaRa Compressed Retrieval (32-64x context reduction)
- Instead of stuffing 100k tokens of document text into the prompt, CLaRa retrieves compressed latent vectors
- The model needs far less working memory per query when documents are involved
- Net effect: a machine struggling with 8k context can effectively handle 100k+ worth of document knowledge
- This is why "Docs mode" often feels faster than plain "Chat mode" with long conversations

### RecursiveLM Scoped Calls
- Instead of one massive prompt, breaks reasoning into small recursive calls over scoped snippets
- Each call uses minimal context (budgeted: 8k tokens max total)
- Memory pressure stays low even for complex multi-hop questions
- The model processes small, focused chunks instead of everything at once

### Combined Effect on Autopilot
The Autopilot recommendation engine factors in all three when scoring models:
- A model scored "Painful" without smart memory becomes "Slow" with it
- Document tasks get a bonus because CLaRa reduces context pressure
- Investigate tasks get a bonus because RecursiveLM keeps calls small
- User sees: "This model is larger than your hardware usually supports, but Studiomc's smart memory makes it work"

## Recommendation Engine ("Autopilot") Algorithm

### Inputs
- VRAM, RAM, disk speed (measured), CPU
- Available backends (Ollama, LM Studio, AirLLM, frontier APIs)
- Models available across all backends
- User intent: chat, documents, coding
- Latency targets
- Smart memory management capabilities (out-of-core available, CLaRa active, RecursiveLM active)

### Heuristic
1. Discover models across all backends (Ollama, LM Studio, AirLLM, frontier)
2. Filter by memory feasibility — apply smart memory bonuses (out-of-core expands feasibility range)
3. Score by: predicted tok/s (from benchmarks or heuristic), model quality tier (params, known family), use case fit (coding vs chat)
4. Apply bonuses: CLaRa active → document tasks score higher for larger models; RecursiveLM → investigate tasks score higher
5. Apply penalties: disk too slow for out-of-core, CPU-only large model, cloud latency for frontier models
6. Prefer local backends over cloud (local gets +20% score bonus)
7. Return top 3 + "bigger slower" list + "cloud options" list (if configured)

### Rules
- Avoid models predicted < 1 tok/s unless user insists
- Prefer smaller models with better responsiveness
- Prefer quantized variants when constrained
- **Local always preferred** — same model on Ollama beats same model on frontier API
- Frontier models only recommended if: no local model meets quality threshold for the task, OR user has explicitly enabled "suggest cloud models"

## Hardware Scan Algorithm
- Quick disk test: sequential read of ~512MB temp file
- Quick inference micro-bench: load minimal model or selected model, measure TTFT + tok/s for 32 tokens
- Store results keyed by hw_fingerprint

## Speed Rating (user-facing)
Derived from: tok/s, TTFT, disk saturation

| Label | Meaning |
|---|---|
| Fast | Responsive |
| OK | Usable |
| Slow | Noticeable lag, suggest smaller model |
| Painful | User must opt in |

## Observability (always local)
- TTFT, tok/s per chat
- RAM/VRAM usage snapshots
- Disk throughput during generation
- Cache hit ratio (if applicable)
- Model load time
- OOM or fallback events

## Support Bundle Export
- One-click "Export diagnostics"
- Includes: logs (sanitized), benchmark results, model metadata, crash dumps
- Never includes chat content unless user explicitly chooses

## CLaRa Performance Targets
- Latent-only answers: TTFT ≤ 2.5s on recommended model, retrieval p95 ≤ 150ms for top-k=8
- Cited answers: TTFT ≤ 4.5s (snippet fetch overhead), citations always shown or "no sources"

## RecursiveLM Budgets (per query)
- Tool calls: 6 max
- Recursion depth: 2 max
- Total retrieved text: 8k tokens hard cap
- Wall-clock: 20s (Investigate mode), 8s (Docs mode)
- If exceeded: return best-effort with "I stopped because..." explanation

## CLaRa Implementation Phases
### Phase 1 (fastest): Preprocessing + retrieval layer
- CLaRa compressor creates compressed vectors for chunks
- Standard generator (local model) with prompt containing top-k compressed vectors + optional minimal text snippets for citations
- Avoids full end-to-end fine-tuning initially

### Phase 2 (better): End-to-end training
- Compression pretraining → compression instruction tuning → end-to-end fine-tuning

### Phase 3 (product-grade): Domain-specific
- Differentiable retrieval training loop for target domain corpora
- Domain-specific SCP-like synthesis (QA + paraphrase supervision)
