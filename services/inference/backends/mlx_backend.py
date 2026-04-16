# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""MLX backend — GPU-accelerated inference on Apple Silicon via mlx-lm.

Uses Apple's MLX framework for Metal-accelerated LLM inference. This
backend is preferred on Apple Silicon Macs because it leverages the
unified memory architecture and Neural Engine for significantly faster
inference compared to llama-cpp-python's CPU/Metal path.

Features:
    - Native Metal GPU acceleration on Apple Silicon
    - Loads safetensors and GGUF models via mlx-lm
    - Streaming chat completions with tok/s metrics
    - Unified memory: no VRAM limitations, uses full system RAM
    - Automatic chat template detection from model config
"""

from __future__ import annotations

import gc
import logging
import os
import platform
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

_SERVICES_DIR = str(Path(__file__).resolve().parent.parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from inference.engine import GenerationMetrics
from inference.backends import BackendClient, BackendInfo, UnifiedModel

logger = logging.getLogger("inference.backends.mlx")

_HAS_MLX = False
_HAS_MLX_LM = False
_IS_APPLE_SILICON = platform.machine() == "arm64" and platform.system() == "Darwin"

if _IS_APPLE_SILICON:
    try:
        import mlx.core as mx  # noqa: F401

        _HAS_MLX = True
    except ImportError:
        logger.info("mlx not installed — mlx backend disabled")

    try:
        import mlx_lm  # noqa: F401

        _HAS_MLX_LM = True
    except ImportError:
        logger.info("mlx-lm not installed — mlx backend disabled")
else:
    logger.info("Not Apple Silicon — mlx backend disabled")

MLX_AVAILABLE = _HAS_MLX and _HAS_MLX_LM and _IS_APPLE_SILICON


def _find_mlx_models(models_dir: Path) -> list[dict[str, Any]]:
    """Find models compatible with mlx-lm in the models directory.

    mlx-lm can load:
    - HuggingFace-format safetensors models (with config.json)
    - Pre-converted MLX models (with config.json + *.safetensors)
    - GGUF models (via mlx-lm's GGUF loader)
    """
    models: list[dict[str, Any]] = []
    if not models_dir.exists():
        return models

    for child in sorted(models_dir.iterdir()):
        if not child.is_dir():
            continue

        config_file = child / "config.json"
        if not config_file.exists():
            continue

        has_safetensors = any(child.glob("*.safetensors")) or (
            child / "model.safetensors.index.json"
        ).exists()
        has_npz = any(child.glob("*.npz"))

        if not has_safetensors and not has_npz:
            continue

        import json

        try:
            with open(config_file) as f:
                cfg = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        if not cfg.get("architectures") and not cfg.get("model_type"):
            continue

        size = sum(
            f.stat().st_size
            for f in child.rglob("*")
            if f.is_file() and f.suffix in (".safetensors", ".npz", ".json")
        )

        model_type = cfg.get("model_type", "unknown")
        model_id = child.name.lower().replace(" ", "-")

        models.append(
            {
                "id": model_id,
                "name": child.name,
                "path": str(child),
                "size_bytes": size,
                "model_type": model_type,
                "context_length": cfg.get("max_position_embeddings"),
            }
        )

    return models


class MLXClient(BackendClient):
    """GPU-accelerated inference on Apple Silicon via mlx-lm.

    This backend uses Apple's MLX framework to run models directly on
    the Metal GPU. It provides significantly better performance than
    CPU-based inference and is the preferred backend on Apple Silicon.
    """

    name = "mlx"

    def __init__(self, models_dir: Path | None = None) -> None:
        from common.config import MODELS_DIR

        self._models_dir = models_dir or MODELS_DIR
        self._model = None
        self._tokenizer = None
        self._active_model_id: str | None = None
        self._active_model_path: Path | None = None
        self._discovered_models: list[dict[str, Any]] = []

    async def probe(self) -> BackendInfo:
        if not MLX_AVAILABLE:
            reason = []
            if not _IS_APPLE_SILICON:
                reason.append("not Apple Silicon")
            if not _HAS_MLX:
                reason.append("mlx not installed")
            if not _HAS_MLX_LM:
                reason.append("mlx-lm not installed")
            return BackendInfo(
                name=self.name,
                online=False,
                error=f"MLX unavailable: {', '.join(reason)}",
            )

        self._discovered_models = _find_mlx_models(self._models_dir)
        online = bool(self._discovered_models) or self._model is not None
        models = [{"id": m["id"]} for m in self._discovered_models]

        return BackendInfo(name=self.name, url=None, online=online, models=models)

    async def list_models(self) -> list[UnifiedModel]:
        await self.probe()

        result: list[UnifiedModel] = []
        for m in self._discovered_models:
            size = m.get("size_bytes")
            params = None
            if size:
                params = round(size / (2 * 1e9), 2)

            result.append(
                UnifiedModel(
                    id=f"mlx/{m['id']}",
                    name=m["name"],
                    backend="mlx",
                    backend_model_id=m["id"],
                    size_bytes=size,
                    params_billion=params,
                    quant="MLX",
                    arch=m.get("model_type"),
                    context_length=m.get("context_length"),
                )
            )
        return result

    def _resolve_model_path(self, model_id: str) -> Path | None:
        for m in self._discovered_models:
            if m["id"] == model_id or m["name"] == model_id:
                return Path(m["path"])

        candidate = self._models_dir / model_id
        if candidate.is_dir() and (candidate / "config.json").exists():
            return candidate

        normalized = model_id.lower().replace(" ", "-")
        for m in self._discovered_models:
            if m["id"].startswith(normalized):
                return Path(m["path"])

        return None

    async def load_model(self, model_id: str) -> bool:
        if not MLX_AVAILABLE:
            logger.error("MLX not available")
            return False

        path = self._resolve_model_path(model_id)
        if path is None:
            logger.error("Model not found for MLX: %s", model_id)
            return False

        if self._model is not None and self._active_model_path == path:
            logger.info("MLX model already loaded: %s", model_id)
            return True

        await self._unload()

        logger.info("Loading model via MLX: %s (%s)", model_id, path)

        try:
            import asyncio

            model, tokenizer = await asyncio.to_thread(
                mlx_lm.load, str(path)
            )
            self._model = model
            self._tokenizer = tokenizer
            self._active_model_id = model_id
            self._active_model_path = path
            logger.info("MLX model loaded: %s", model_id)
            return True
        except Exception as e:
            logger.exception("Failed to load MLX model %s: %s", model_id, e)
            self._model = None
            self._tokenizer = None
            self._active_model_id = None
            self._active_model_path = None
            return False

    async def _unload(self) -> None:
        if self._model is not None:
            del self._model
            del self._tokenizer
            self._model = None
            self._tokenizer = None
            self._active_model_id = None
            self._active_model_path = None
            gc.collect()

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        if self._model is None:
            loaded = await self.load_model(model_id)
            if not loaded:
                yield "[Error: Could not load MLX model]", GenerationMetrics()
                return

        import asyncio

        temperature = kwargs.get("temperature") or 0.7
        max_tokens = kwargs.get("max_tokens") or 2048

        try:
            if hasattr(self._tokenizer, "apply_chat_template"):
                prompt = self._tokenizer.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=True
                )
            else:
                prompt = "\n".join(
                    f"{m.get('role', 'user')}: {m.get('content', '')}"
                    for m in messages
                )
                prompt += "\nassistant: "
        except Exception:
            prompt = "\n".join(
                f"{m.get('role', 'user')}: {m.get('content', '')}"
                for m in messages
            )
            prompt += "\nassistant: "

        t0 = time.perf_counter()
        ttft = 0.0
        tokens_generated = 0
        first_token = True

        try:
            gen_kwargs = {
                "temp": temperature,
                "max_tokens": max_tokens,
            }

            for token_text in mlx_lm.stream_generate(
                self._model, self._tokenizer, prompt=prompt, **gen_kwargs
            ):
                if first_token:
                    ttft = (time.perf_counter() - t0) * 1000
                    first_token = False
                tokens_generated += 1
                yield token_text, None
                await asyncio.sleep(0)

        except Exception as e:
            logger.exception("MLX generation error: %s", e)
            yield f"[Error: {e}]", None

        elapsed_ms = (time.perf_counter() - t0) * 1000
        tok_per_s = (
            tokens_generated / (elapsed_ms / 1000.0) if elapsed_ms > 0 else 0
        )

        metrics = GenerationMetrics(
            prompt_tokens=0,
            completion_tokens=tokens_generated,
            total_tokens=tokens_generated,
            ttft_ms=round(ttft),
            tok_per_s=round(tok_per_s, 2),
            elapsed_ms=round(elapsed_ms),
        )
        yield "", metrics

    async def generate(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        if self._model is None:
            loaded = await self.load_model(model_id)
            if not loaded:
                return "[Error: Could not load MLX model]", GenerationMetrics()

        import asyncio

        temperature = kwargs.get("temperature") or 0.7
        max_tokens = kwargs.get("max_tokens") or 2048

        try:
            if hasattr(self._tokenizer, "apply_chat_template"):
                prompt = self._tokenizer.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=True
                )
            else:
                prompt = "\n".join(
                    f"{m.get('role', 'user')}: {m.get('content', '')}"
                    for m in messages
                )
                prompt += "\nassistant: "
        except Exception:
            prompt = "\n".join(
                f"{m.get('role', 'user')}: {m.get('content', '')}"
                for m in messages
            )
            prompt += "\nassistant: "

        t0 = time.perf_counter()

        try:
            text = await asyncio.to_thread(
                mlx_lm.generate,
                self._model,
                self._tokenizer,
                prompt=prompt,
                temp=temperature,
                max_tokens=max_tokens,
            )

            elapsed_ms = (time.perf_counter() - t0) * 1000
            est_tokens = len(text.split())
            tok_per_s = est_tokens / (elapsed_ms / 1000.0) if elapsed_ms > 0 else 0

            metrics = GenerationMetrics(
                prompt_tokens=0,
                completion_tokens=est_tokens,
                total_tokens=est_tokens,
                ttft_ms=round(elapsed_ms),
                tok_per_s=round(tok_per_s, 2),
                elapsed_ms=round(elapsed_ms),
            )
            return text, metrics

        except Exception as e:
            logger.exception("MLX generation error: %s", e)
            elapsed_ms = (time.perf_counter() - t0) * 1000
            return f"[Error: {e}]", GenerationMetrics(elapsed_ms=round(elapsed_ms))

    async def close(self) -> None:
        await self._unload()
