# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Guards the split-bundle Core/Pro boundary (see SPLIT_BUNDLE.md).

These tests run in CI **before** the heavy Pro pack is installed. They
verify that importing any Core module — and constructing the public
``InferenceEngine`` shell — never triggers a ``torch`` (or other Pro)
import. If you find yourself "fixing" a test here by adding the heavy
library to the allow-list, stop and read SPLIT_BUNDLE.md instead.
"""

from __future__ import annotations

import builtins
import importlib
import sys
from collections.abc import Callable

import pytest

# Anything in this set must not be imported as a side effect of loading
# Core modules. Add new heavy libs here as they appear.
PRO_ONLY_MODULES: set[str] = {
    "torch",
    "transformers",
    "peft",
    "accelerate",
    "sentence_transformers",
    "safetensors",
    "mlx",
    "mlx_lm",
    "llama_cpp",
}


@pytest.fixture
def block_pro_imports(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Replace ``__import__`` with a guard that records & blocks Pro modules.

    Returns the list of Pro module names something *attempted* to import.
    Modules that catch the ImportError gracefully (e.g. via
    ``try: import mlx`` blocks) will appear in the list but won't fail
    the test — the test only fails if the importing module itself
    propagates the ImportError.
    """
    attempted: list[str] = []
    original: Callable[..., object] = builtins.__import__

    def guarded(name: str, *args: object, **kwargs: object) -> object:
        root = name.split(".", 1)[0]
        if root in PRO_ONLY_MODULES:
            attempted.append(name)
            raise ImportError(f"Pro module '{name}' blocked in Core test")
        return original(name, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(builtins, "__import__", guarded)
    # Drop any cached imports from previous tests so the guard runs.
    for mod in list(sys.modules):
        root = mod.split(".", 1)[0]
        if root in PRO_ONLY_MODULES or mod.startswith("inference"):
            sys.modules.pop(mod, None)
    return attempted


CORE_MODULES: list[str] = [
    "inference.engine_types",
    "inference.engine",                      # class shell, lazy torch
    "inference.core",                        # package only — no eager re-exports
    "inference.core.switch_types",           # pure dataclass
    "inference.core.memory_guard",           # uses psutil, not torch
    "inference.core.adapter_loader",         # graceful: try/except peft
    "inference.llama_server_sidecar",        # native sidecar wrapper
    "inference.backends",
    "inference.backends.ollama",
    "inference.backends.lmstudio",
    "inference.backends.frontier",
    "inference.backends.llama_server",       # new HTTP backend, no native deps
    "inference.backends.llamacpp",           # graceful: try/except llama_cpp
    "inference.backends.mlx_backend",        # graceful: try/except mlx
    "inference.backends.studiomc",
    "inference.router",                      # constructs without torch
    "common.pro_pack",
    "clara.compressor",                      # 3-tier embed (sbert → llama → tfidf)
]


@pytest.mark.parametrize("module_name", CORE_MODULES)
def test_core_module_imports_without_pro_pack(
    block_pro_imports: list[str],
    module_name: str,
) -> None:
    """Each Core module must be importable on a Pro-pack-free machine."""
    importlib.import_module(module_name)


def test_inference_engine_constructs_without_torch(
    block_pro_imports: list[str],
) -> None:
    """``InferenceEngine()`` must not import torch — only ``load_model`` does."""
    from inference.engine import InferenceEngine

    engine = InferenceEngine()
    assert engine.is_loaded is False
    assert engine.active_model_id is None
    # Sanity: nothing in the Pro set was *propagated* during construction.
    # (Graceful degradations elsewhere may have logged attempts.)


def test_load_model_raises_pro_pack_required(
    block_pro_imports: list[str],
) -> None:
    """Without the Pro pack, ``load_model`` must fail with a clear error."""
    import asyncio

    from inference.engine import InferenceEngine

    engine = InferenceEngine()
    with pytest.raises(RuntimeError, match="Pro pack"):
        asyncio.run(engine.load_model("fake-id", "/nonexistent/path"))


def test_inference_router_constructs_without_pro_pack(
    block_pro_imports: list[str],
) -> None:
    """The full :class:`InferenceRouter` must boot on a Core-only install.

    The router registers every built-in backend (Ollama, LM Studio, MLX,
    llama_server, llamacpp, studiomc). Each one's module top-level must
    therefore stay torch-free, and the router must lazy-import any Pro
    helpers (``safe_switch`` etc.) inside the methods that need them.
    """
    from inference.engine import InferenceEngine
    from inference.router import InferenceRouter

    engine = InferenceEngine()
    router = InferenceRouter(engine)

    expected = {"ollama", "lmstudio", "mlx", "llama_server", "llamacpp", "studiomc"}
    assert expected.issubset(set(router._backends.keys()))
    # llama_server must be in the priority list so it wins for GGUFs.
    assert "llama_server" in router.BACKEND_PRIORITY


def test_llama_server_sidecar_reports_missing_binary_cleanly(
    block_pro_imports: list[str],
) -> None:
    """When no binary is available the sidecar must report it, not crash."""
    from inference.llama_server_sidecar import find_llama_server_binary

    # Test environments don't ship the binary — that's fine, just verify
    # the discovery function returns ``None`` instead of raising.
    result = find_llama_server_binary()
    assert result is None or result.is_file()


def test_clara_compressor_falls_back_to_tfidf(
    block_pro_imports: list[str],
) -> None:
    """CLaRa must produce embeddings even with no Pro pack and no model loaded.

    With ``sentence_transformers`` blocked (Pro absent) AND the
    llama-server sidecar idle (no model loaded), :func:`encode_texts`
    should silently fall back to the TF-IDF hashing path so the user
    can still index documents during onboarding.
    """
    from clara import compressor

    assert compressor.active_backend() == "tfidf-hash"
    vecs = compressor.encode_texts(["hello world", "second chunk"])
    assert vecs.shape == (2, compressor.get_dims())
    assert vecs.dtype.name == "float32"
