# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec — bundle all Studiomc Core Python services into one directory.

Usage:
    cd services
    pyinstaller studiomc_services.spec --clean

The resulting ``dist/studiomc_services/`` directory contains a single
executable (``studiomc_services``) plus all shared libraries and data.
The Flutter app copies this directory into its platform-specific resources
folder at build time.

Core vs Pro split (see ``services/SPLIT_BUNDLE.md``):
    * This spec ships ONLY the Core bundle: FastAPI services + the
      ``llama-server`` sidecar. No PyTorch, transformers, peft, accelerate,
      sentence-transformers, mlx, or llama_cpp_python — those live in the
      optional Pro pack tarball that the supervisor downloads into
      ``~/.studiomc/pro-env`` on demand.
    * The training service registers its routes lazily and any code path
      that needs the heavy ML stack raises ``ProPackRequiredError``,
      which is converted to HTTP 412 by ``common/fastapi_pro_pack.py``.
    * Heavy libs are listed in the ``excludes`` block below so they can
      never leak into the Core bundle. NOTE: PyInstaller does NOT fail the
      build when an excluded module is imported; the import simply fails
      at runtime inside the frozen bundle. That is exactly how the
      v0.9.9.x releases shipped with a dead inference service. The real
      guard is ``scripts/build/smoke_bundle.py``, which launches every
      service from the built bundle and asserts ``/health``.
"""

import platform
from pathlib import Path

block_cipher = None

# ── Symbol stripping ───────────────────────────────────────────────────────
# macOS only. On Linux, PyInstaller runs binutils ``strip`` over every
# collected shared library, and Ubuntu 22.04's strip (binutils 2.38)
# corrupts the program headers of numpy's vendored OpenBLAS
# (``numpy.libs/libscipy_openblas64_-*.so``). The frozen bundle then dies
# on ``import numpy`` with "ELF load command address/offset not
# page-aligned", which is exactly what the v0.9.9.8 Linux release build
# hit in the bundle self-test. Windows has no strip at all.
STRIP_BINARIES = platform.system() == "Darwin"

# ── Paths ──────────────────────────────────────────────────────────────────
# PyInstaller runs with CWD = this spec file's directory (services/)
SERVICES_ROOT = Path(".")

# ── Hidden imports ─────────────────────────────────────────────────────────
# Modules that PyInstaller's static analysis may miss because they are
# loaded dynamically (importlib, lazy imports in frameworks, etc.).
hidden_imports = [
    # FastAPI / Starlette / Uvicorn internals
    "uvicorn.logging",
    "uvicorn.loops",
    "uvicorn.loops.auto",
    "uvicorn.protocols",
    "uvicorn.protocols.http",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.lifespan",
    "uvicorn.lifespan.on",
    "uvicorn.lifespan.off",
    "multipart",
    "multipart.multipart",
    "email.mime.multipart",
    # Child services — imported via importlib in bundle_entry.py
    "inference.app",
    "model_manager.app",
    "documents.app",
    "clara.app",
    "lre.app",
    "orchestrator.app",
    "data_recipes.app",
    "data_recipes.routes",
    "data_recipes.recipe_engine",
    "mcp.app",
    "mcp.routes",
    "mcp.broker",
    "mcp.client",
    "memory.app",
    "memory.routes",
    "memory.store",
    "memory.extractor",
    # Service internals that routes/app files may lazy-import
    "inference.routes",
    "inference.streaming",
    "inference.engine_types",
    "inference.llama_server_sidecar",
    "inference.backends.llama_server",
    # NOTE: inference.backends.llamacpp is intentionally NOT listed.
    # It depends on llama_cpp_python (Pro pack only). The router skips it
    # at runtime when the import fails, and the Core bundle should not
    # try to drag llama_cpp into the frozen archive.
    "model_manager.routes",
    "model_manager.autopilot",
    "documents.routes",
    "clara.routes",
    "clara.retriever",
    "lre.routes",
    "lre.tools",
    "orchestrator.routes",
    "orchestrator.reasoning",
    "training.app",
    "training.routes",
    "supervisor.routes",
    "supervisor.manager",
    # Common utilities
    "common.config",
    "common.build_info",
    "common.hardware",
    "common.schemas",
    "common.database",
    "common.pro_pack",
    "common.pro_pack_installer",
    "common.fastapi_pro_pack",
    # Standard libraries that sometimes need nudging
    "numpy",
    "aiosqlite",
    "httpx",
    "platformdirs",
    "psutil",
    # File I/O
    "aiofiles",
    # NOTE: torch / transformers / peft / accelerate / sentence_transformers
    # / mlx / llama_cpp are NOT listed here. They live in the Pro pack venv
    # (~/.studiomc/pro-env) and are imported by the training service via
    # the Pro pack's separate Python interpreter, NOT inside this frozen
    # bundle. See ``excludes`` below for the matching guardrail.
]

# ── Data files ─────────────────────────────────────────────────────────────
# Include every service package so that importlib.import_module() can find
# them at runtime. PyInstaller treats these as data (not analysed for
# imports) — that's fine since we list the key modules in hidden_imports.
datas = [
    ("inference", "inference"),
    ("model_manager", "model_manager"),
    ("documents", "documents"),
    ("clara", "clara"),
    ("lre", "lre"),
    ("orchestrator", "orchestrator"),
    ("supervisor", "supervisor"),
    ("training", "training"),
    ("data_recipes", "data_recipes"),
    ("mcp", "mcp"),
    ("memory", "memory"),
    ("common", "common"),
]

# The llama-server sidecar binary (services/bin, populated by
# scripts/build/fetch_llama_server.sh). PyInstaller >= 6 places data under
# ``_internal/``, so at runtime it lives at ``sys._MEIPASS / "bin"``; see
# ``inference/llama_server_sidecar.py`` for the discovery order. Without
# it the Core bundle has no built-in inference engine, so fail the build.
if not (SERVICES_ROOT / "bin").is_dir():
    raise SystemExit(
        "services/bin/ is missing: run scripts/build/fetch_llama_server.sh "
        "before building the bundle."
    )
datas.append(("bin", "bin"))

# Build identity written by scripts/build/build_services.sh; reported by
# the supervisor's /health so the app can detect stale supervisors.
if (SERVICES_ROOT / "BUILD_INFO.json").is_file():
    datas.append(("BUILD_INFO.json", "."))

# ── Analysis ───────────────────────────────────────────────────────────────
a = Analysis(
    ["bundle_entry.py"],
    pathex=[str(SERVICES_ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hidden_imports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        # Large packages we definitely don't need in production
        "tkinter",
        "matplotlib",
        "test",
        "unittest",
        "setuptools",
        "pip",
        "wheel",
        # ── Pro pack only — must NOT leak into the Core bundle ────────────
        # These are excluded so that PyInstaller's static analysis emits a
        # build error if any Core module accidentally imports them at
        # module load time. The Pro pack ships its own venv with these
        # libraries; the supervisor invokes them via a subprocess.
        "torch",
        "torchvision",
        "torchaudio",
        "transformers",
        "peft",
        "accelerate",
        "sentence_transformers",
        "mlx",
        "mlx.core",
        "mlx.nn",
        "mlx_lm",
        "llama_cpp",
        "safetensors",
        "datasets",
        "huggingface_hub",
        "tokenizers",
    ],
    noarchive=False,
    optimize=1,
    cipher=block_cipher,
)

# ── Remove unnecessary large files ────────────────────────────────────────
# Strip test directories and other dead weight from collected data.
a.datas = [
    d for d in a.datas
    if not any(
        part in d[0]
        for part in ("tests/", "test/", "__pycache__/", ".dist-info/")
    )
]

# ── PYZ (compressed python modules) ───────────────────────────────────────
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

# ── EXE ────────────────────────────────────────────────────────────────────
exe = EXE(
    pyz,
    a.scripts,
    [],  # Don't merge into single file — use COLLECT for onedir
    exclude_binaries=True,
    name="studiomc_services",
    debug=False,
    bootloader_ignore_signals=False,
    strip=STRIP_BINARIES,
    upx=False,  # UPX causes issues on macOS ARM
    console=True,
    # macOS-specific
    codesign_identity=None,
    entitlements_file=None,
)

# ── COLLECT (onedir output) ───────────────────────────────────────────────
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=STRIP_BINARIES,
    upx=False,
    name="studiomc_services",
)
