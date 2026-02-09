<p align="center">
  <img src="studiomc_app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_128.png" width="80" />
</p>

<h1 align="center">Studiomc</h1>

<p align="center">
  <strong>Private AI that runs on your machine. No cloud. No account. No compromise.</strong>
</p>

<p align="center">
  <a href="https://github.com/mchawda/studiomc/releases/latest"><img src="https://img.shields.io/github/v/release/mchawda/studiomc?style=flat-square&color=4A90D9" alt="Release" /></a>
  <a href="https://github.com/mchawda/studiomc/blob/main/LICENSES/MIT.txt"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/flutter-dart-02569B?style=flat-square&logo=flutter" alt="Flutter" />
</p>

<p align="center">
  <img src=".github/assets/hero-screenshot.png" width="720" alt="Studiomc Chat" />
</p>

---

Studiomc is a desktop AI assistant that runs large language models entirely on your hardware. It auto-detects your system, recommends the best model, and gives you a ChatGPT-quality experience — fully offline, fully private.

## Why Studiomc

| Problem | Studiomc |
|---|---|
| Local AI tools feel like dev tools | Polished UI — install, click, chat |
| Users pick the wrong model and get frustrated | Hardware scan + automatic model recommendation |
| Document Q&A is slow and uncited | CLaRa compression-native retrieval with citations |
| No way to know if a model will run well | Speed ratings and performance predictions in plain English |
| Multiple backends, multiple interfaces | One unified interface across Ollama, LM Studio, and frontier APIs |

## Features

- **One-click install** — Working chat in under 2 minutes
- **Autopilot model selection** — Scans your hardware, picks the best model automatically
- **Multi-backend** — Auto-detects Ollama and LM Studio, connects frontier APIs (OpenAI, Anthropic)
- **Chat** — Streaming responses, conversation history, branching, memory
- **Docs mode** — Upload PDF/TXT/MD, ask questions, get cited answers
- **Investigate mode** — Deep-dive with full reasoning trace visibility
- **Performance dashboard** — Speed rating (Fast/OK/Slow), throughput, system metrics
- **Smart memory management** — Run bigger models on less hardware via out-of-core inference
- **Local OpenAI-compatible API** — Integrate with any tool that speaks OpenAI
- **Privacy-first** — Everything runs locally. No telemetry. No accounts. No cloud unless you explicitly opt in.

## Quick Start

**No prerequisites. No Ollama. No Python. Just install and chat.**

### Install from Release

1. Download the latest `.dmg` from [Releases](https://github.com/mchawda/studiomc/releases/latest)
2. Open the DMG and drag **Studiomc** to Applications
3. Launch Studiomc — it scans your hardware and recommends a model
4. The model downloads from HuggingFace automatically
5. You're chatting in under 2 minutes

> **Note:** The app is currently unsigned. On first launch, right-click the app and select "Open" to bypass macOS Gatekeeper.

### Optional: Ollama / LM Studio

If you already have [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) installed, Studiomc auto-detects them and adds their models to your model list. No configuration needed.

### Build from Source

```bash
# Clone
git clone https://github.com/mchawda/studiomc.git
cd studiomc

# Build macOS app + DMG
./scripts/build-macos.sh

# Output: dist/Studiomc-<version>-macos.dmg
```

Requires: [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel)

## Architecture

```
Flutter App ── HTTP/WS ──▶ Local Supervisor
                              ├── Inference Router
                              │     ├── Ollama (auto-detected)
                              │     ├── LM Studio (auto-detected)
                              │     ├── AirLLM Engine (built-in)
                              │     └── Frontier APIs (optional)
                              ├── Model Manager
                              ├── Document Service
                              ├── CLaRa RAG Service
                              └── Local Reasoning Environment
```

- **Frontend:** Flutter (Dart) — macOS, Windows, iOS, Android
- **Inference:** Bundled llama.cpp engine (Metal GPU acceleration), with optional Ollama / LM Studio / frontier API backends
- **Models:** Downloaded from HuggingFace on demand (GGUF format)
- **Backend:** Python FastAPI — embedded runtime for advanced features (document search, reasoning)
- **Storage:** SQLite + filesystem

## Project Structure

```
studiomc/
  studiomc_app/           # Flutter app
    lib/
      screens/            # Chat, Models, Documents, Settings, etc.
      widgets/            # Reusable UI components
      services/           # API clients, inference, settings
      models/             # Data models
  services/               # Python backend
    supervisor/           # Process manager
    inference/            # AirLLM + inference routing
    model_manager/        # Model downloads & registry
    documents/            # Document extraction & indexing
    clara/                # Compression-native retrieval
    lre/                  # Local Reasoning Environment
    orchestrator/         # Recursive reasoning loop
  scripts/                # Build & release tooling
  product/                # Product specs & design docs
```

## Performance Targets

| Metric | Target |
|---|---|
| Install to first chat | ≤ 2 min |
| First token latency | ≤ 2.5s (recommended models) |
| Throughput | ≥ 10 tok/s GPU, ≥ 4 tok/s CPU |
| Document retrieval | p95 ≤ 150ms |

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## Credits

Built on the shoulders of:
- [AirLLM](https://github.com/lyogavin/airllm) — Out-of-core inference
- [Ollama](https://ollama.com) — Local model runtime
- [Flutter](https://flutter.dev) — Cross-platform UI

## License

[MIT](LICENSES/MIT.txt)
