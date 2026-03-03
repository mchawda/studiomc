# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec — bundle all Studiomc Python services into one directory.

Usage:
    cd services
    pyinstaller studiomc_services.spec --clean

The resulting ``dist/studiomc_services/`` directory contains a single
executable (``studiomc_services``) plus all shared libraries and data.
The Flutter app copies this directory into its platform-specific resources
folder at build time.
"""

import platform
from pathlib import Path

block_cipher = None

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
    # Service internals that routes/app files may lazy-import
    "inference.routes",
    "inference.streaming",
    "inference.backends.llamacpp",
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
    "common.hardware",
    "common.schemas",
    "common.database",
    # Heavy libraries that sometimes need nudging
    "numpy",
    "tiktoken",
    "tiktoken_ext",
    "tiktoken_ext.openai_public",
    "aiosqlite",
    "httpx",
    "platformdirs",
    # llama.cpp GGUF inference engine
    "llama_cpp",
    "llama_cpp.llama",
    "llama_cpp.llama_cpp",
    # File I/O
    "aiofiles",
    # PyTorch submodules needed to avoid circular imports in frozen bundles
    "torch.autograd",
    "torch.autograd.function",
    "torch.autograd.variable",
    "torch.nn",
    "torch.nn.functional",
    "torch.nested",
    "torch.nested._internal",
    "torch.nested._internal.nested_tensor",
    "torch.utils",
    "torch.utils.data",
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
    ("common", "common"),
]

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
    strip=platform.system() != "Windows",
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
    strip=platform.system() != "Windows",
    upx=False,
    name="studiomc_services",
)
