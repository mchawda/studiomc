"""SpliceLLM inference engine — wraps the out-of-core engine for the service layer.

Provides the public API used by the router and backends:
    - load_model / unload_model
    - generate_stream / generate
    - GenerationMetrics, EngineState, PROFILE_PARAMS

No mock mode. No echo mode. If PyTorch is not installed or no model is
loaded, clear errors are raised.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import AsyncIterator

logger = logging.getLogger("inference.engine")

# ── Verify PyTorch is available ──────────────────────────────────────

try:
    import torch  # noqa: F401
except ImportError:
    raise ImportError(
        "PyTorch is required for inference. Install with: pip install torch"
    )

from inference.core.out_of_core import OutOfCoreEngine


# ── Data classes ──────────────────────────────────────────────────────

@dataclass
class GenerationMetrics:
    """Metrics collected during a single generation."""
    ttft_ms: int = 0          # time to first token
    tok_per_s: float = 0.0    # tokens per second
    total_tokens: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    elapsed_ms: int = 0


@dataclass
class EngineState:
    """Tracks current engine state."""
    active_model_id: str | None = None
    active_model_path: str | None = None
    loaded: bool = False
    generating: bool = False


# ── Profile presets ───────────────────────────────────────────────────

PROFILE_PARAMS = {
    "fast": {
        "temperature": 0.5,
        "max_new_tokens": 256,
        "repetition_penalty": 1.1,
        "top_p": 0.85,
    },
    "balanced": {
        "temperature": 0.7,
        "max_new_tokens": 1024,
        "repetition_penalty": 1.15,
        "top_p": 0.9,
    },
    "quality": {
        "temperature": 0.8,
        "max_new_tokens": 2048,
        "repetition_penalty": 1.2,
        "top_p": 0.95,
    },
}


class InferenceEngine:
    """Wraps the OutOfCoreEngine for local model inference.

    Usage::

        engine = InferenceEngine()
        await engine.load_model("model-id", "/path/to/model")
        async for token, metrics in engine.generate_stream(messages, profile="balanced"):
            print(token, end="", flush=True)
    """

    def __init__(self) -> None:
        self.state = EngineState()
        self._engine = OutOfCoreEngine()
        self._lock = asyncio.Lock()

    @property
    def is_loaded(self) -> bool:
        return self.state.loaded

    @property
    def active_model_id(self) -> str | None:
        return self.state.active_model_id

    # ── Model lifecycle ───────────────────────────────────────────────

    async def load_model(self, model_id: str, model_path: str) -> None:
        """Load a model for out-of-core inference. Unloads previous model first."""
        async with self._lock:
            if self.state.active_model_id == model_id and self.state.loaded:
                logger.info("Model %s already loaded", model_id)
                return

            await self._unload_internal()

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
        if self.state.loaded:
            logger.info("Unloading model %s", self.state.active_model_id)
            await self._engine.unload_model()
            self.state.active_model_id = None
            self.state.active_model_path = None
            self.state.loaded = False

    # ── Generation (streaming) ────────────────────────────────────────

    async def generate_stream(
        self,
        messages: list[dict[str, str]],
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
        messages: list[dict[str, str]],
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
    def _format_prompt(messages: list[dict[str, str]]) -> str:
        """Convert chat messages to a single prompt string.

        Uses a simple ChatML-style format. Model-specific templates
        can be added later.
        """
        parts: list[str] = []
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            parts.append(f"<|{role}|>\n{content}")
        parts.append("<|assistant|>\n")
        return "\n".join(parts)
