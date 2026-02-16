# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""llama.cpp backend — built-in GGUF model inference via llama-cpp-python.

This is the primary local inference engine for Studiomc. It runs GGUF
models directly without requiring Ollama, LM Studio, or any external
tool.

Features:
    - Loads any GGUF model from ~/.studiomc/models/
    - GPU acceleration via Metal (macOS) and CUDA (Linux/Windows)
    - Streaming chat completions with tok/s metrics
    - Automatic context sizing based on available memory
"""

from __future__ import annotations

import glob
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from inference.engine import GenerationMetrics
from inference.backends import BackendClient, BackendInfo, UnifiedModel

logger = logging.getLogger("inference.backends.llamacpp")

# Try to import llama-cpp-python
try:
    from llama_cpp import Llama

    LLAMACPP_AVAILABLE = True
except ImportError:
    LLAMACPP_AVAILABLE = False
    logger.info("llama-cpp-python not installed — llamacpp backend disabled")


def _find_gguf_files(models_dir: Path) -> list[Path]:
    """Recursively find all .gguf files in the models directory."""
    files: list[Path] = []
    if not models_dir.exists():
        return files
    for p in models_dir.rglob("*.gguf"):
        if p.is_file():
            files.append(p)
    return sorted(files, key=lambda p: p.name)


def _model_id_from_path(path: Path) -> str:
    """Derive a clean model id from a GGUF file path."""
    return path.stem.lower().replace(" ", "-")


def _human_name(path: Path) -> str:
    """Derive a readable name from a GGUF filename."""
    name = path.stem
    # Remove common suffixes
    for suffix in ["-Q4_K_M", "-Q5_K_M", "-Q8_0", "-Q4_0", "-Q6_K", "-IQ4_XS"]:
        name = name.replace(suffix, "")
    name = (
        name.replace("-", " ")
        .replace("_", " ")
        .replace(".gguf", "")
        .strip()
    )
    # Title-case words
    parts = []
    for word in name.split():
        if word[0:1].isdigit() or word.isupper():
            parts.append(word)
        else:
            parts.append(word.capitalize())
    return " ".join(parts) if parts else path.stem


class LlamaCppClient(BackendClient):
    """Runs GGUF models locally via llama-cpp-python.

    This is Studiomc's built-in inference engine. It requires no external
    tools — just download a GGUF model and go.
    """

    name = "llamacpp"

    def __init__(self, models_dir: Path | None = None) -> None:
        from common.config import MODELS_DIR

        self._models_dir = models_dir or MODELS_DIR
        self._llm: "Llama | None" = None
        self._active_model_id: str | None = None
        self._active_model_path: Path | None = None
        self._discovered_models: list[dict[str, Any]] = []

    # ── Discovery ─────────────────────────────────────────────────────

    async def probe(self) -> BackendInfo:
        """Scan the models directory for GGUF files."""
        if not LLAMACPP_AVAILABLE:
            return BackendInfo(
                name=self.name,
                online=False,
                error="llama-cpp-python not installed",
            )

        files = _find_gguf_files(self._models_dir)
        self._discovered_models = []
        for path in files:
            mid = _model_id_from_path(path)
            size = path.stat().st_size
            self._discovered_models.append({
                "id": mid,
                "name": _human_name(path),
                "path": str(path),
                "size_bytes": size,
            })

        models = [{"id": m["id"]} for m in self._discovered_models]

        # Also count as online if a model is already loaded
        online = bool(files) or self._llm is not None

        return BackendInfo(
            name=self.name,
            url=None,
            online=online,
            models=models,
        )

    async def list_models(self) -> list[UnifiedModel]:
        """Return discovered GGUF models."""
        # Re-scan if empty
        if not self._discovered_models:
            await self.probe()

        result: list[UnifiedModel] = []
        for m in self._discovered_models:
            size = m.get("size_bytes")
            params = None
            if size:
                # Rough estimate: Q4_K_M ≈ 0.56 bytes/param
                params = round(size / (0.56 * 1e9), 2)

            result.append(UnifiedModel(
                id=m["id"],
                name=m["name"],
                backend="llamacpp",
                backend_model_id=m["id"],
                size_bytes=size,
                params_billion=params,
                quant="GGUF",
            ))
        return result

    # ── Model loading ─────────────────────────────────────────────────

    def _resolve_model_path(self, model_id: str) -> Path | None:
        """Find the GGUF file for a given model id.

        Handles multiple ID formats:
        - Absolute file path: /path/to/model.gguf
        - Full filename: llama-3.2-3b-instruct-q4_k_m.gguf
        - Stem ID: llama-3.2-3b-instruct-q4_k_m
        - Partial match: llama-3.2-3b
        """
        # Direct path
        if os.path.isfile(model_id) and model_id.endswith(".gguf"):
            return Path(model_id)

        # Normalize: strip .gguf/.bin extension, lowercase, dash-for-space
        normalized = (
            model_id.replace(".gguf", "")
            .replace(".bin", "")
            .lower()
            .replace(" ", "-")
        )

        # Check discovered models (exact or normalized match)
        for m in self._discovered_models:
            if m["id"] == model_id or m["id"] == normalized:
                return Path(m["path"])

        # Search models directory
        for path in _find_gguf_files(self._models_dir):
            stem_id = _model_id_from_path(path)
            if stem_id == model_id or stem_id == normalized:
                return path

        # Partial match: model_id is a prefix of the file stem
        for path in _find_gguf_files(self._models_dir):
            stem_id = _model_id_from_path(path)
            if stem_id.startswith(normalized):
                return path

        # Check by subdirectory name
        subdir = self._models_dir / model_id
        if subdir.is_dir():
            ggufs = list(subdir.glob("*.gguf"))
            if ggufs:
                return ggufs[0]

        return None

    async def load_model(self, model_id: str) -> bool:
        """Load a GGUF model into memory.

        Automatically configures:
        - GPU layers (all layers on GPU for Metal/CUDA)
        - Context length (4096 default, tunable)
        - Chat format (chatml for most models)
        """
        if not LLAMACPP_AVAILABLE:
            logger.error("llama-cpp-python not installed")
            return False

        path = self._resolve_model_path(model_id)
        if path is None:
            logger.error("Model not found: %s", model_id)
            return False

        # If same model already loaded, skip
        if self._llm is not None and self._active_model_path == path:
            logger.info("Model already loaded: %s", model_id)
            return True

        # Unload previous model
        await self._unload()

        logger.info("Loading GGUF model: %s (%s)", model_id, path)

        try:
            self._llm = Llama(
                model_path=str(path),
                n_ctx=4096,
                n_gpu_layers=-1,  # offload all layers to GPU
                verbose=False,
                # Don't set chat_format — auto-detect from GGUF metadata.
                # Modern GGUF files embed their chat template, so
                # llama-cpp-python uses the correct one automatically.
            )
            self._active_model_id = model_id
            self._active_model_path = path
            logger.info("Model loaded: %s", model_id)
            return True
        except Exception as e:
            logger.exception("Failed to load model %s: %s", model_id, e)
            self._llm = None
            self._active_model_id = None
            self._active_model_path = None
            return False

    async def _unload(self) -> None:
        """Unload the current model and free memory."""
        if self._llm is not None:
            try:
                del self._llm
                self._llm = None
            except Exception:
                pass
            self._active_model_id = None
            self._active_model_path = None

            # Force garbage collection
            import gc
            gc.collect()

    # ── Generation ────────────────────────────────────────────────────

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Stream tokens from the loaded GGUF model."""
        if self._llm is None:
            # Try to load the model
            loaded = await self.load_model(model_id)
            if not loaded:
                yield "[Error: Could not load model]", GenerationMetrics(
                    prompt_tokens=0,
                    completion_tokens=0,
                    total_tokens=0,
                    ttft_ms=0,
                    tok_per_s=0.0,
                    elapsed_ms=0,
                )
                return

        temperature = kwargs.get("temperature") or 0.7
        max_tokens = kwargs.get("max_tokens") or 2048

        t0 = time.perf_counter()
        ttft = 0.0
        tokens_generated = 0
        first_token = True

        try:
            response = self._llm.create_chat_completion(
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
                stream=True,
            )

            for chunk in response:
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content", "")
                if content:
                    if first_token:
                        ttft = (time.perf_counter() - t0) * 1000
                        first_token = False
                    tokens_generated += 1
                    yield content, None

                # Check for finish
                finish = chunk.get("choices", [{}])[0].get("finish_reason")
                if finish:
                    break

        except Exception as e:
            logger.exception("Generation error: %s", e)
            yield f"[Error: {e}]", None

        elapsed_ms = (time.perf_counter() - t0) * 1000
        tok_per_s = (
            tokens_generated / (elapsed_ms / 1000.0) if elapsed_ms > 0 else 0
        )

        metrics = GenerationMetrics(
            prompt_tokens=0,  # llama.cpp doesn't expose this in streaming
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
        """Non-streaming generation."""
        if self._llm is None:
            loaded = await self.load_model(model_id)
            if not loaded:
                return "[Error: Could not load model]", GenerationMetrics(
                    prompt_tokens=0,
                    completion_tokens=0,
                    total_tokens=0,
                    ttft_ms=0,
                    tok_per_s=0.0,
                    elapsed_ms=0,
                )

        temperature = kwargs.get("temperature") or 0.7
        max_tokens = kwargs.get("max_tokens") or 2048

        t0 = time.perf_counter()

        try:
            response = self._llm.create_chat_completion(
                messages=messages,
                temperature=temperature,
                max_tokens=max_tokens,
                stream=False,
            )

            text = response["choices"][0]["message"]["content"]
            usage = response.get("usage", {})
            prompt_tokens = usage.get("prompt_tokens", 0)
            completion_tokens = usage.get("completion_tokens", 0)

            elapsed_ms = (time.perf_counter() - t0) * 1000
            tok_per_s = (
                completion_tokens / (elapsed_ms / 1000.0) if elapsed_ms > 0 else 0
            )

            metrics = GenerationMetrics(
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
                total_tokens=prompt_tokens + completion_tokens,
                ttft_ms=round(elapsed_ms),  # non-streaming: TTFT ≈ elapsed
                tok_per_s=round(tok_per_s, 2),
                elapsed_ms=round(elapsed_ms),
            )
            return text, metrics

        except Exception as e:
            logger.exception("Generation error: %s", e)
            elapsed_ms = (time.perf_counter() - t0) * 1000
            return f"[Error: {e}]", GenerationMetrics(
                prompt_tokens=0,
                completion_tokens=0,
                total_tokens=0,
                ttft_ms=0,
                tok_per_s=0.0,
                elapsed_ms=round(elapsed_ms),
            )

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def close(self) -> None:
        """Unload the model and free resources."""
        await self._unload()
