# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""SpliceLLM inference engine — wraps the out-of-core engine for the service layer.

Provides the public API used by the router and backends:
    - load_model / unload_model
    - generate_stream / generate

The pure data types (``GenerationMetrics``, ``EngineState``,
``PROFILE_PARAMS``) live in :mod:`inference.engine_types` so that
lightweight backends (Ollama, LM Studio, Frontier, llama-server) can
import them without dragging in the heavy Pro pack (PyTorch + the
``OutOfCoreEngine``).

The Pro pack — ``torch`` + ``inference.core.out_of_core`` — is imported
**lazily inside :meth:`InferenceEngine.load_model`**. Constructing an
``InferenceEngine`` is free; only loading a SpliceLLM model triggers
the Pro pack import. If the Pro pack is not installed, ``load_model``
raises a clear error and the router falls back to other backends.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, AsyncIterator

# Re-export the pure types so existing call sites that do
# ``from inference.engine import GenerationMetrics`` keep working until
# they migrate to ``inference.engine_types``.
from inference.engine_types import (
    PROFILE_PARAMS,
    EngineState,
    GenerationMetrics,
)

logger = logging.getLogger("inference.engine")


def _load_pro_pack() -> Any:
    """Import the SpliceLLM dependencies on demand.

    Raises a friendly error if the Pro pack (PyTorch + transformers +
    safetensors + accelerate) is not installed. This is the **only**
    place in the inference service that triggers a torch import — keep
    it that way to preserve the small Core bundle.
    """
    try:
        import torch  # noqa: F401

        from inference.core.out_of_core import OutOfCoreEngine
    except ImportError as exc:  # pragma: no cover — pro pack absent
        raise RuntimeError(
            "The SpliceLLM engine requires the Studiomc Pro pack "
            "(PyTorch + transformers). Install it from the Training "
            "screen or via `pip install studiomc-services[pro]`."
        ) from exc
    return OutOfCoreEngine


class InferenceEngine:
    """Wraps the OutOfCoreEngine for local model inference.

    Constructing an instance is free — the heavy ML stack is only
    imported the first time :meth:`load_model` is called. This keeps
    the Core bundle slim while preserving the existing public API for
    call sites that already hold a long-lived engine reference.

    Usage::

        engine = InferenceEngine()
        await engine.load_model("model-id", "/path/to/model")
        async for token, metrics in engine.generate_stream(messages, profile="balanced"):
            print(token, end="", flush=True)
    """

    def __init__(self) -> None:
        self.state = EngineState()
        # Lazily created by load_model — kept None until the Pro pack
        # is verified, so importing this module never touches torch.
        self._engine: Any = None
        self._lock = asyncio.Lock()

    @property
    def is_loaded(self) -> bool:
        return self.state.loaded

    @property
    def active_model_id(self) -> str | None:
        return self.state.active_model_id

    # ── Model lifecycle ───────────────────────────────────────────────

    async def load_model(self, model_id: str, model_path: str) -> None:
        """Load a model for out-of-core inference. Unloads previous model first.

        First call lazily imports the Pro pack and constructs the
        underlying ``OutOfCoreEngine``. Subsequent calls reuse it.
        """
        async with self._lock:
            if self.state.active_model_id == model_id and self.state.loaded:
                logger.info("Model %s already loaded", model_id)
                return

            await self._unload_internal()

            # Lazy Pro-pack import — happens exactly once per process.
            if self._engine is None:
                out_of_core_cls = _load_pro_pack()
                self._engine = out_of_core_cls()

            logger.info("Loading model %s from %s", model_id, model_path)
            await self._engine.load_model(model_path)
            logger.info("Model %s loaded successfully", model_id)

            self.state.active_model_id = model_id
            self.state.active_model_path = model_path
            self.state.loaded = True

    async def unload_model(self) -> None:
        """Unload the current model and free memory."""
        async with self._lock:
            await self._unload_internal()

    async def _unload_internal(self) -> None:
        if self.state.loaded and self._engine is not None:
            logger.info("Unloading model %s", self.state.active_model_id)
            await self._engine.unload_model()
            self.state.active_model_id = None
            self.state.active_model_path = None
            self.state.loaded = False

    # ── Generation (streaming) ────────────────────────────────────────

    async def generate_stream(
        self,
        messages: list[dict[str, Any]],
        *,
        profile: str = "balanced",
        temperature: float | None = None,
        max_tokens: int | None = None,
        slowmode: bool = False,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Yield (token, metrics_or_none) tuples. Final yield has metrics."""
        if not self.state.loaded:
            raise RuntimeError("No model loaded. Call load_model() first.")

        self.state.generating = True
        params = {**PROFILE_PARAMS.get(profile, PROFILE_PARAMS["balanced"])}
        if temperature is not None:
            params["temperature"] = temperature
        if max_tokens is not None:
            params["max_new_tokens"] = max_tokens

        prompt = self._format_prompt(messages)
        metrics = GenerationMetrics()
        metrics.prompt_tokens = max(len(prompt.split()), 1)  # rough estimate

        start = time.perf_counter()
        first_token_time: float | None = None
        token_count = 0

        try:
            async for token in self._engine.generate_stream(
                prompt,
                max_new_tokens=params.get("max_new_tokens", 512),
                temperature=params.get("temperature", 0.7),
                top_p=params.get("top_p", 0.9),
                repetition_penalty=params.get("repetition_penalty", 1.15),
            ):
                if first_token_time is None:
                    first_token_time = time.perf_counter()
                    metrics.ttft_ms = int((first_token_time - start) * 1000)
                token_count += 1
                if slowmode:
                    await asyncio.sleep(0.05)
                yield token, None

            elapsed = time.perf_counter() - start
            metrics.completion_tokens = token_count
            metrics.total_tokens = metrics.prompt_tokens + token_count
            metrics.elapsed_ms = int(elapsed * 1000)
            metrics.tok_per_s = token_count / max(elapsed, 0.001)

            # Final yield carries the completed metrics
            yield "", metrics

        finally:
            self.state.generating = False

    # ── Non-streaming generation ──────────────────────────────────────

    async def generate(
        self,
        messages: list[dict[str, Any]],
        *,
        profile: str = "balanced",
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> tuple[str, GenerationMetrics]:
        """Generate full response (non-streaming). Returns (text, metrics)."""
        tokens: list[str] = []
        metrics: GenerationMetrics | None = None
        async for token, m in self.generate_stream(
            messages,
            profile=profile,
            temperature=temperature,
            max_tokens=max_tokens,
        ):
            if m is not None:
                metrics = m
            else:
                tokens.append(token)
        return "".join(tokens), metrics or GenerationMetrics()

    # ── Prompt formatting ─────────────────────────────────────────────

    @staticmethod
    def _format_prompt(messages: list[dict[str, Any]]) -> str:
        """Convert chat messages to a single prompt string.

        Uses a simple ChatML-style format. Model-specific templates
        can be added later.  Multimodal content arrays are flattened to
        text-only (images are not supported by SpliceLLM).
        """
        parts: list[str] = []
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            # Handle multimodal content arrays
            if isinstance(content, list):
                text_parts = [
                    p.get("text", "") for p in content
                    if isinstance(p, dict) and p.get("type") == "text"
                ]
                content = " ".join(text_parts)
            parts.append(f"<|{role}|>\n{content}")
        parts.append("<|assistant|>\n")
        return "\n".join(parts)
