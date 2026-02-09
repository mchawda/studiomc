# Product Overview

## Product Name
Studiomc

## Description
A mass-market, "ChatGPT-easy" desktop app that runs open local models with maximum usability, privacy, and predictable performance. Built on AirLLM's out-of-core capabilities (https://github.com/lyogavin/airllm), rewritten where possible. One codebase (Flutter) for macOS, Windows, and mobile. The app makes all smart decisions — users never see complexity.

> **Non-negotiable truth:** "70B on 4GB" is a capability demo, not a pleasant experience. The product wins by making the right model feel great on each machine.

## Problems
- Existing local AI tools feel like GitHub projects, not products
- Users get disappointed running large models on consumer hardware without guardrails
- Traditional RAG is slow, inaccurate, and provides weak citations
- No jargon-free way to pick the right model for your hardware

## Solutions
- Connect to any model backend — Ollama, LM Studio, HuggingFace, or frontier APIs (OpenAI, Anthropic, etc.)
- Auto-recommend the best model across all available backends — users never choose
- Smart memory management (AirLLM out-of-core + CLaRa compression + RecursiveLM) lets bigger models run on weaker hardware
- Transparent performance predictions in plain English
- CLaRa compression-native retrieval for fast cited document chat
- Local Reasoning Environment for deep tool-assisted investigation
- Everything works out of the box in under 2 minutes

## Key Features
1. One-click install (macOS, Windows, mobile)
2. Hardware scan + automatic model recommendation ("Autopilot") across all backends
3. Multi-backend model support — auto-detects Ollama and LM Studio, built-in AirLLM engine, optional frontier APIs
4. Model library (curated, HuggingFace, Ollama library, local import — import in advanced only)
5. Smart memory management — run larger models on limited hardware via out-of-core inference, compressed retrieval, and recursive reasoning
6. Chat UI with streaming, history, presets (Default/Writing/Coding/Tutor), branching
7. Document chat with citations (CLaRa-first, RAG-lite fallback)
8. Investigate mode with recursive reasoning + safe tools (LRE)
9. Performance dashboard with Speed Rating (Fast/OK/Slow/Painful)
10. Local OpenAI-compatible API + frontier model API support (advanced, clearly labeled "cloud")
11. Groundedness meter — % of answer supported by sources
12. Explainable trace panel — show what the model searched/opened/cited

## Scope Boundaries (what we will NOT promise)
- No promise that 70B on 4GB VRAM is "smooth" — allowed only behind experience warnings, "Slow mode", benchmarked estimate, and explicit user acknowledgement
- No "agent that hacks systems," no exploit tooling
- No hidden telemetry — opt-in only

## UX Principles
1. Instant gratification — working chat in under 2 minutes
2. No jargon — replace "VRAM" with "graphics memory", "quantization" with "compressed model", "out-of-core" with "runs from disk (slower)"
3. Performance honesty — predict and explain constraints in plain English
4. Safety by default — local privacy, no hidden network calls
5. App decides everything — users get a great experience without choices
6. Always provide a recommended alternative when warning about slow models

## Experience Targets
- Install to first message: ≤ 2 min (excluding model download)
- TTFT (recommended models): ≤ 2.5s typical
- TTFT (large but allowed models): ≤ 8s typical with warnings
- Tokens/sec (recommended): ≥ 10 tok/s GPU, ≥ 4 tok/s CPU
- Crashes: 0 during normal usage; safe recovery with clear message if model fails
- Model download: resumable, checksum verified
- CLaRa latent-only answers: TTFT ≤ 2.5s, retrieval p95 ≤ 150ms (top-k=8)
- CLaRa cited answers: TTFT ≤ 4.5s, citations always shown

## Differentiators
- **Multi-backend, one interface** — Ollama, LM Studio, AirLLM, frontier APIs all appear as one unified model list. User doesn't care where the model runs.
- **The "Right Model" autopilot** — pick best model automatically across ALL backends for machine and task
- **Run bigger models on less hardware** — AirLLM out-of-core + CLaRa 32-64x compression + RecursiveLM small-context calls = models that normally need 32GB run usably on 8GB
- **Transparent performance** — no confusion, no disappointment
- **Best-in-class local UX** — feels like ChatGPT, not a GitHub project
- **CLaRa + RecursiveLM** — documents actually work, with trust
- **Local-first, cloud-optional** — prefer local models always; frontier APIs available but clearly labeled with privacy consent

## User Roles
1. **User** — Single local user, no accounts. Private AI assistant.

## Tech Stack
- **App:** Flutter (Dart) — macOS, Windows, iOS, Android
- **Services:** Python 3.11+ (embedded runtime), FastAPI + WebSockets
- **Inference backends:** Ollama (auto-detected), LM Studio (auto-detected), AirLLM (built-in out-of-core engine), Frontier APIs (OpenAI-compatible, user-configured)
- **Storage:** SQLite (metadata, chat history, doc index state) + filesystem (model blobs, extracted text, embeddings)
- **Embeddings:** Local small model, pluggable provider interface
- **Intelligence:** CLaRa compression-native RAG, Local Reasoning Environment (LRE), Recursive Orchestrator
- **Memory management:** AirLLM out-of-core (disk-streamed layers), CLaRa 32-64x context compression, RecursiveLM scoped small-context calls
- **Deployment:** Fully offline capable, no cloud dependency, frontier API integrations disabled by default and require explicit consent
