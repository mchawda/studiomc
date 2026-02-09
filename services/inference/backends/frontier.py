"""Frontier API backend client.

Communicates with any OpenAI-compatible cloud API:
    - OpenAI      (https://api.openai.com)
    - Anthropic   (via OpenAI-proxy or native)
    - Google      (via OpenAI-compatible proxy)
    - Mistral     (https://api.mistral.ai)
    - Any other   (configurable base_url + api_key)

Uses the standard OpenAI chat completions protocol:
    - GET  /v1/models            — list available models
    - POST /v1/chat/completions  — chat completion (SSE streaming)

Cloud requests require explicit user consent (consent flag checked by the router).
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
    PROBE_TIMEOUT,
)

logger = logging.getLogger("inference.backends.frontier")


class FrontierClient(BackendClient):
    """Talks to any OpenAI-compatible API (OpenAI, Anthropic proxy, etc.).

    Supports:
        - Configurable base URL and API key
        - Optional model list override (skip /v1/models probing)
        - SSE streaming for chat completions
        - Provider-specific naming (e.g., "frontier:openai/gpt-4o")
    """

    name = "frontier"

    def __init__(
        self,
        base_url: str,
        api_key: str,
        provider_name: str = "frontier",
        models_override: list[str] | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.provider_name = provider_name
        self._models_override = models_override  # skip /v1/models call if set
        self._client = httpx.AsyncClient(
            base_url=self.base_url,
            timeout=120.0,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
        )

    # ── Discovery ─────────────────────────────────────────────────────

    async def probe(self) -> BackendInfo:
        """Check if the frontier API is reachable.

        If models_override was set at construction time, skip the
        network call and report those models directly.
        """
        info = BackendInfo(
            name=f"frontier:{self.provider_name}", url=self.base_url
        )
        if self._models_override:
            info.online = True
            info.models = [{"id": m} for m in self._models_override]
            return info
        try:
            resp = await self._client.get(
                "/v1/models", timeout=PROBE_TIMEOUT * 2
            )
            resp.raise_for_status()
            data = resp.json()
            info.online = True
            info.models = data.get("data", [])
        except Exception as e:
            info.online = False
            info.error = str(e)
        return info

    async def list_models(self) -> list[UnifiedModel]:
        """Return available models, either from override or /v1/models."""
        backend_label = f"frontier:{self.provider_name}"

        if self._models_override:
            return [
                UnifiedModel(
                    id=f"{backend_label}/{m}",
                    name=m,
                    backend=backend_label,
                    backend_model_id=m,
                )
                for m in self._models_override
            ]

        try:
            resp = await self._client.get(
                "/v1/models", timeout=PROBE_TIMEOUT * 2
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception:
            return []

        models: list[UnifiedModel] = []
        for m in data.get("data", []):
            mid = m.get("id", "")
            models.append(UnifiedModel(
                id=f"{backend_label}/{mid}",
                name=mid,
                backend=backend_label,
                backend_model_id=mid,
                details=m,
            ))
        return models

    # ── Generation ────────────────────────────────────────────────────

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Stream tokens from POST /v1/chat/completions (SSE).

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
                            metrics.ttft_ms = int(
                                (first_token_time - start) * 1000
                            )
                        token_count += 1
                        yield content, None

                    # Check for usage in the final chunk
                    usage = chunk.get("usage")
                    if usage:
                        metrics.prompt_tokens = usage.get("prompt_tokens", 0)
                        metrics.completion_tokens = usage.get(
                            "completion_tokens", token_count
                        )
                        metrics.total_tokens = usage.get("total_tokens", 0)

        except Exception as e:
            logger.error(
                "Frontier (%s) streaming error: %s", self.provider_name, e
            )
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
