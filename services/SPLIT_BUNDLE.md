# Split-bundle architecture (Option E)

This document is the **contract** between the Core bundle and the Pro
pack. Every layer that imports a heavy ML library must read this first.

## Two artefacts

| Artefact       | Size       | Contains                                                        | Shipped how                                  |
| -------------- | ---------- | --------------------------------------------------------------- | -------------------------------------------- |
| **Core bundle**| ~80–150 MB | FastAPI services, `llama-server` sidecar binary, lightweight RAG (TF-IDF / llama-server `/embedding`), supervisor, model manager, document pipeline | DMG / AppImage / MSI shipped from GitHub Releases. PyInstaller `--onedir`. Code-signed. |
| **Pro pack**   | ~1.0–1.3 GB| Standalone CPython 3.11 venv with `torch`, `transformers`, `peft`, `accelerate`, `sentence-transformers`, `safetensors`, `mlx`/`mlx_lm` (Apple Silicon), plus the SpliceLLM out-of-core engine wheel | tarball downloaded from GitHub Releases on first use; extracted to user data dir |

The Core bundle **never** imports torch. Period. CI enforces this with
the smoke test in `services/tests/test_core_imports.py` (next task).

## Disk layout

```
~/Library/Application Support/Studiomc/        (macOS, see common/config.py)
├── db/app.sqlite
├── models/<model_id>/blobs/
├── docs/, indexes/, logs/, cache/, adapters/
├── pro-env/                                   ← Pro pack lives here
│   ├── VERSION                                ← e.g. "0.1.0"
│   ├── INSTALLED_AT                           ← ISO-8601 timestamp
│   ├── manifest.json                          ← packages + sha256 of tarball
│   ├── bin/python                             ← venv interpreter
│   └── lib/python3.11/site-packages/
│       ├── torch/, transformers/, peft/, ...
└── llama-bin/                                 ← llama.cpp sidecar
    ├── llama-server                           ← precompiled binary
    └── VERSION
```

The Pro pack is a self-contained relocatable venv. We do **not** install
into the system Python and we do **not** mix it with the app's bundled
Python (which would defeat the size/sign goals).

## Module ownership

| Module / package                    | Tier     | Notes                                                                     |
| ----------------------------------- | -------- | ------------------------------------------------------------------------- |
| `inference/engine_types.py`         | Core     | Pure dataclasses — torch-free.                                            |
| `inference/engine.py`               | Core     | Class shell; `load_model()` lazy-imports torch via `_load_pro_pack()`.    |
| `inference/core/out_of_core.py`     | Pro      | SpliceLLM. Imports torch.                                                 |
| `inference/backends/{ollama,lmstudio,frontier}.py` | Core | HTTP clients, no ML deps.                                          |
| `inference/backends/llamacpp.py`    | Core     | Will be replaced by the `llama-server` sidecar (next task).               |
| `inference/backends/studiomc.py`    | Core     | Holds an `InferenceEngine` reference; only triggers Pro on `load_model`.  |
| `inference/backends/mlx_backend.py` | Pro      | Already gracefully degrades; supervisor must not import on Core-only.     |
| `clara/compressor.py` (sentence-transformers path) | Pro | Falls back to llama-server `/embedding` (or TF-IDF) when Pro absent. |
| `training/*`                        | Pro      | Always runs in a child process spawned with `pro-env/bin/python`.         |
| `common/pro_pack.py`                | Core     | Single source of truth for install state. **Read this before importing torch anywhere.** |

## API contract for Pro-required features

Endpoints that need the Pro pack must call `common.pro_pack.require()`
before doing any heavy work:

```python
from common.pro_pack import require, ProPackRequiredError

@router.post("/training/start")
async def start_training(req: TrainRequest):
    require("training")     # raises ProPackRequiredError if missing
    # safe to import torch / transformers / mlx below this line
    from training.lora_trainer import LoraTrainer
    ...
```

A FastAPI exception handler converts `ProPackRequiredError` into:

```http
HTTP/1.1 412 Precondition Failed
Content-Type: application/json

{
  "error": "pro_pack_required",
  "feature": "training",
  "required_version": "0.1.0",
  "installed_version": null
}
```

The Flutter UI maps `pro_pack_required` to the install dialog
(`First-time training-pack download UX`, todo `e5-bootstrap-ux`).

## Supervisor routing

The supervisor (`services/supervisor/manager.py`) decides where each
service runs:

| Service        | Interpreter                                            |
| -------------- | ------------------------------------------------------ |
| supervisor     | bundled Core Python                                    |
| inference      | bundled Core Python (uses llama-server over HTTP)      |
| model_manager  | bundled Core Python                                    |
| documents      | bundled Core Python                                    |
| clara          | bundled Core Python (uses llama-server `/embedding`)   |
| lre            | bundled Core Python                                    |
| orchestrator   | bundled Core Python                                    |
| data_recipes   | bundled Core Python                                    |
| **training**   | `pro-env/bin/python` — spawned on demand, killed when idle |

Routing is implemented in `e7-supervisor-routing` and uses the
`pro_python_path()` helper from `common/pro_pack.py`.

## llama-server sidecar (replaces `llama-cpp-python` in Core)

The Core bundle ships `llama-server` (the standalone HTTP server from
upstream `llama.cpp`) as a precompiled binary in `~/.studiomc/llama-bin/`.

| Concern         | Decision                                                                  |
| --------------- | ------------------------------------------------------------------------- |
| Acquisition     | CI downloads the official release for each platform/arch from `ggerganov/llama.cpp` and checksums the binary into the bundle. |
| Lifecycle       | Owned by the supervisor. Started on first chat request, stopped after 5 min of idle. |
| Port            | `127.0.0.1:8190` (after `INFERENCE_PORT`).                                |
| Auth            | None (loopback only).                                                     |
| API             | OpenAI-compatible `/v1/chat/completions` + `/v1/embeddings` + `/health`.  |
| Model selection | The supervisor invokes `llama-server -m <gguf-path> -ngl 999 --port 8190 ...` per loaded model; one process per loaded model. |
| Backend client  | New `inference/backends/llama_server.py` — pure HTTP, no native deps.     |

The new `llama_server` backend replaces both:

* `inference/backends/llamacpp.py` (which depended on `llama-cpp-python`)
* The embedding path in `clara/compressor.py` for users without the Pro pack.

`llama-cpp-python` is removed from `pyproject.toml` Core dependencies
once the sidecar lands (todo `e3-llama-server`).

## Pro pack versioning & upgrade

* Tarball name: `studiomc-pro-{version}-{platform}-{arch}.tar.zst`
  (e.g. `studiomc-pro-0.1.0-macos-arm64.tar.zst`).
* Hosted on the `pro-pack-vX.Y.Z` GitHub release.
* `manifest.json` is shipped alongside and pinned by sha256 in the Core
  bundle's `common/pro_pack_index.py` (added in `e4-training-pack`).
* On every Core launch, the supervisor compares
  `PRO_VERSION_FILE` against `REQUIRED_PRO_VERSION`. If the installed
  pack is older, the UI shows an "Upgrade Pro pack" prompt (non-blocking
  for chat — only blocks Training screen entry).

## What the user sees

1. **Day 0**: Downloads `Studiomc.dmg` (~120 MB), opens app. Chat works
   immediately (Ollama detected → use it; otherwise download a small GGUF
   that runs through `llama-server`).
2. **Day N**: Clicks "Train your own model". A dialog explains the Pro
   pack (~1.2 GB), shows progress, installs into `pro-env/`, then opens
   the training screen.
3. **Day N+1**: Pro pack is permanent; future training sessions launch
   instantly via the `pro-env/bin/python` subprocess.

## Migration order (this PR sequence)

1. ✅ `e1-inventory` — tag every module Core vs Pro.
2. ✅ `e2-pyproject-split` — `pro` and `mlx` extras; remove heavy deps from Core.
3. ✅ `engine.py` lazy-loads torch via `_load_pro_pack()`.
4. ✅ `engine_types.py` carries pure types; all backends migrated.
5. ✅ `common/pro_pack.py` — status, paths, `require()` guard.
6. ⏳ `e3-llama-server` — sidecar wrapper + new `llama_server` backend.
7. ⏳ `e4-training-pack` — tarball builder + installer in supervisor.
8. ⏳ `e5-bootstrap-ux` — Flutter download dialog wired to status API.
9. ⏳ `e6-spec-strip` — drop torch/transformers/peft from PyInstaller spec.
10. ⏳ `e7-supervisor-routing` — spawn training in `pro-env/bin/python`.
