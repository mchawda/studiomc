"""Ollama backend client.

Communicates with a local Ollama instance via its REST API:
    - GET  /api/tags  — list loaded models
    - POST /api/chat  — chat completion (streaming NDJSON)

Default endpoint: http://localhost:11434
"""

from __future__ import annotations

import json
import logging
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

import httpx

from inference.engine import GenerationMetrics
from inference.backends import (
    BackendClient,
    BackendInfo,
    UnifiedModel,
    OLLAMA_DEFAULT_URL,
    PROBE_TIMEOUT,
)

logger = logging.getLogger("inference.backends.ollama")


class OllamaClient(BackendClient):
    """Talks to a local Ollama instance.

    Ollama uses its own REST API (not OpenAI-compatible) with NDJSON
    streaming for chat completions.
    """

    name = "ollama"

    def __init__(self, base_url: str = OLLAMA_DEFAULT_URL) -> None:
        self.base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(base_url=self.base_url, timeout=60.0)

    # ── Discovery ─────────────────────────────────────────────────────

    async def probe(self) -> BackendInfo:
        """Probe Ollama at /api/tags to check availability."""
        info = BackendInfo(name=self.name, url=self.base_url)
        try:
            resp = await self._client.get("/api/tags", timeout=PROBE_TIMEOUT)
            resp.raise_for_status()
            data = resp.json()
            info.online = True
            raw_models = data.get("models", [])
            info.models = raw_models
            logger.info("Ollama online — %d model(s) found", len(raw_models))
        except Exception as e:
            info.online = False
            info.error = str(e)
            logger.debug("Ollama not available: %s", e)
        return info

    async def list_models(self) -> list[UnifiedModel]:
        """Fetch the model list from /api/tags and convert to UnifiedModel."""
        try:
            resp = await self._client.get("/api/tags", timeout=PROBE_TIMEOUT)
            resp.raise_for_status()
            data = resp.json()
        except Exception:
            return []

        models: list[UnifiedModel] = []
        for m in data.get("models", []):
            model_name = m.get("name", "")
            details = m.get("details", {})
            size = m.get("size")
            models.append(UnifiedModel(
                id=f"ollama/{model_name}",
                name=model_name,
                backend="ollama",
                backend_model_id=model_name,
                size_bytes=size,
                params_billion=details.get("parameter_size"),
                quant=details.get("quantization_level"),
                arch=details.get("family"),
                context_length=None,
                details=details,
            ))
        return models

    # ── Generation ────────────────────────────────────────────────────

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Stream tokens from Ollama's POST /api/chat (NDJSON).

        Yields (token, None) for each token, then ("", metrics) at the end.
        """
        payload: dict[str, Any] = {
            "model": model_id,
            "messages": messages,
            "stream": True,
        }
        if "temperature" in kwargs and kwargs["temperature"] is not None:
            payload.setdefault("options", {})["temperature"] = kwargs["temperature"]
        if "max_tokens" in kwargs and kwargs["max_tokens"] is not None:
            payload.setdefault("options", {})["num_predict"] = kwargs["max_tokens"]

        metrics = GenerationMetrics()
        start = time.perf_counter()
        first_token_time: float | None = None
        token_count = 0

        try:
            async with self._client.stream(
                "POST", "/api/chat", json=payload, timeout=300.0
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.strip():
                        continue
                    chunk = json.loads(line)
                    content = chunk.get("message", {}).get("content", "")
                    if content:
                        if first_token_time is None:
                            first_token_time = time.perf_counter()
                            metrics.ttft_ms = int((first_token_time - start) * 1000)
                        token_count += 1
                        yield content, None

                    if chunk.get("done"):
                        # Extract Ollama's own metrics if available
                        eval_count = chunk.get("eval_count", token_count)
                        prompt_eval_count = chunk.get("prompt_eval_count", 0)
                        elapsed = time.perf_counter() - start
                        metrics.completion_tokens = eval_count
                        metrics.prompt_tokens = prompt_eval_count
                        metrics.total_tokens = eval_count + prompt_eval_count
                        metrics.elapsed_ms = int(elapsed * 1000)
                        metrics.tok_per_s = eval_count / max(elapsed, 0.001)
                        break

        except Exception as e:
            logger.error("Ollama streaming error: %s", e)
            raise

        yield "", metrics

    async def generate(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        """Non-streaming generation via streaming under the hood."""
        tokens: list[str] = []
        metrics = GenerationMetrics()
        async for token, m in self.generate_stream(model_id, messages, **kwargs):
            if m is not None:
                metrics = m
            else:
                tokens.append(token)
        return "".join(tokens), metrics

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def close(self) -> None:
        await self._client.aclose()
