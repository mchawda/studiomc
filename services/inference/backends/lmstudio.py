# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""LM Studio backend client.

Communicates with a local LM Studio instance via its OpenAI-compatible API:
    - GET  /v1/models            — list loaded models
    - POST /v1/chat/completions  — chat completion (SSE streaming)

Default endpoint: http://localhost:1234
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
    LMSTUDIO_DEFAULT_URL,
    PROBE_TIMEOUT,
)

logger = logging.getLogger("inference.backends.lmstudio")


class LMStudioClient(BackendClient):
    """Talks to a local LM Studio instance (OpenAI-compatible API).

    LM Studio exposes an OpenAI-compatible API with SSE streaming,
    making it easy to support as a drop-in alternative to Ollama.
    """

    name = "lmstudio"

    def __init__(self, base_url: str = LMSTUDIO_DEFAULT_URL) -> None:
        self.base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(base_url=self.base_url, timeout=60.0)

    # ── Discovery ─────────────────────────────────────────────────────

    async def probe(self) -> BackendInfo:
        """Probe LM Studio at /v1/models to check availability."""
        info = BackendInfo(name=self.name, url=self.base_url)
        try:
            resp = await self._client.get("/v1/models", timeout=PROBE_TIMEOUT)
            resp.raise_for_status()
            data = resp.json()
            info.online = True
            raw_models = data.get("data", [])
            info.models = raw_models
            logger.info("LM Studio online — %d model(s) found", len(raw_models))
        except Exception as e:
            info.online = False
            info.error = str(e)
            logger.debug("LM Studio not available: %s", e)
        return info

    async def list_models(self) -> list[UnifiedModel]:
        """Fetch the model list from /v1/models and convert to UnifiedModel."""
        try:
            resp = await self._client.get("/v1/models", timeout=PROBE_TIMEOUT)
            resp.raise_for_status()
            data = resp.json()
        except Exception:
            return []

        models: list[UnifiedModel] = []
        for m in data.get("data", []):
            model_id = m.get("id", "")
            models.append(UnifiedModel(
                id=f"lmstudio/{model_id}",
                name=model_id,
                backend="lmstudio",
                backend_model_id=model_id,
                details=m,
            ))
        return models

    # ── Generation ────────────────────────────────────────────────────

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Stream tokens from LM Studio's POST /v1/chat/completions (SSE).

        Yields (token, None) for each token, then ("", metrics) at the end.
        """
        payload: dict[str, Any] = {
            "model": model_id,
            "messages": messages,
            "stream": True,
        }
        if "temperature" in kwargs and kwargs["temperature"] is not None:
            payload["temperature"] = kwargs["temperature"]
        if "max_tokens" in kwargs and kwargs["max_tokens"] is not None:
            payload["max_tokens"] = kwargs["max_tokens"]

        metrics = GenerationMetrics()
        start = time.perf_counter()
        first_token_time: float | None = None
        token_count = 0

        try:
            async with self._client.stream(
                "POST", "/v1/chat/completions", json=payload, timeout=300.0
            ) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith("data: "):
                        line = line[6:]
                    if line == "[DONE]":
                        break

                    try:
                        chunk = json.loads(line)
                    except Exception:
                        continue

                    choices = chunk.get("choices", [])
                    if not choices:
                        continue

                    delta = choices[0].get("delta", {})
                    content = delta.get("content", "")
                    if content:
                        if first_token_time is None:
                            first_token_time = time.perf_counter()
                            metrics.ttft_ms = int((first_token_time - start) * 1000)
                        token_count += 1
                        yield content, None

                    # Check for usage in the final chunk
                    usage = chunk.get("usage")
                    if usage:
                        metrics.prompt_tokens = usage.get("prompt_tokens", 0)
                        metrics.completion_tokens = usage.get("completion_tokens", token_count)
                        metrics.total_tokens = usage.get("total_tokens", 0)

        except Exception as e:
            logger.error("LM Studio streaming error: %s", e)
            raise

        elapsed = time.perf_counter() - start
        if not metrics.completion_tokens:
            metrics.completion_tokens = token_count
            metrics.total_tokens = metrics.prompt_tokens + token_count
        metrics.elapsed_ms = int(elapsed * 1000)
        metrics.tok_per_s = token_count / max(elapsed, 0.001)

        yield "", metrics

    async def generate(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
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
