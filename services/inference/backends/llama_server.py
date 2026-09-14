# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""``llama-server`` backend client — the new built-in Studiomc inference path.

This backend talks to the ``llama-server`` sidecar (precompiled
``llama.cpp`` binary) over its OpenAI-compatible HTTP API. It replaces
``LlamaCppClient`` in the Core bundle so we no longer ship the heavy
``llama-cpp-python`` Python wheel (300+ MB on macOS arm64).

Discovery model
---------------
* ``probe()`` scans ``~/.studiomc/models/`` for ``*.gguf`` files. Each
  file is reported as an available model. We do NOT spawn the sidecar
  during probe — only when a model is actually selected for inference.
* ``list_models()`` re-scans on every call so newly downloaded models
  show up immediately in the UI.

Streaming
---------
``llama-server`` supports OpenAI-compatible SSE streaming. We parse the
``data: {…}`` chunks and yield each ``delta.content`` token as it
arrives, with ``GenerationMetrics`` populated from the final ``usage``
block (and timed locally for TTFT / tok/s).
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, AsyncIterator

import httpx

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from inference.backends import BackendClient, BackendInfo, UnifiedModel
from inference.engine_types import GenerationMetrics
from inference.llama_server_sidecar import (
    LlamaServerError,
    LlamaServerSidecar,
    find_llama_server_binary,
    get_sidecar,
)

logger = logging.getLogger("inference.backends.llama_server")


# ── Filename helpers (kept identical to llamacpp.py for ID compat) ────

def _find_gguf_files(models_dir: Path) -> list[Path]:
    if not models_dir.exists():
        return []
    files = [p for p in models_dir.rglob("*.gguf") if p.is_file()]
    return sorted(files, key=lambda p: p.name)


def _model_id_from_path(path: Path) -> str:
    return path.stem.lower().replace(" ", "-")


def _human_name(path: Path) -> str:
    name = path.stem
    for suffix in ("-Q4_K_M", "-Q5_K_M", "-Q8_0", "-Q4_0", "-Q6_K", "-IQ4_XS"):
        name = name.replace(suffix, "")
    name = name.replace("-", " ").replace("_", " ").replace(".gguf", "").strip()
    parts: list[str] = []
    for word in name.split():
        if word[0:1].isdigit() or word.isupper():
            parts.append(word)
        else:
            parts.append(word.capitalize())
    return " ".join(parts) if parts else path.stem


# ── Backend client ────────────────────────────────────────────────────

class LlamaServerClient(BackendClient):
    """Built-in GGUF inference via the ``llama-server`` sidecar.

    The sidecar is shared across the whole process — spawned once per
    loaded model and shut down by the idle watchdog. Multiple chat
    requests against the same model run concurrently inside the
    sidecar's own queue.
    """

    name = "llama_server"

    def __init__(
        self,
        models_dir: Path | None = None,
        sidecar: LlamaServerSidecar | None = None,
    ) -> None:
        from common.config import MODELS_DIR

        self._models_dir = models_dir or MODELS_DIR
        self._sidecar_override = sidecar
        self._discovered: list[dict[str, Any]] = []

    async def _get_sidecar(self) -> LlamaServerSidecar:
        return self._sidecar_override or await get_sidecar()

    # ── Discovery ─────────────────────────────────────────────────────

    async def probe(self) -> BackendInfo:
        binary = find_llama_server_binary()
        if binary is None:
            return BackendInfo(
                name=self.name,
                online=False,
                error=(
                    "llama-server binary not installed. "
                    "Run scripts/build/fetch_llama_server.sh "
                    "or set $STUDIOMC_LLAMA_SERVER."
                ),
            )

        files = _find_gguf_files(self._models_dir)
        self._discovered = [
            {
                "id": _model_id_from_path(p),
                "name": _human_name(p),
                "path": str(p),
                "size_bytes": p.stat().st_size,
            }
            for p in files
        ]

        return BackendInfo(
            name=self.name,
            url=None,
            online=True,  # binary available counts as online; no models is fine
            models=[{"id": m["id"]} for m in self._discovered],
        )

    async def list_models(self) -> list[UnifiedModel]:
        await self.probe()
        result: list[UnifiedModel] = []
        for m in self._discovered:
            size = m.get("size_bytes")
            params = round(size / (0.56 * 1e9), 2) if size else None
            result.append(UnifiedModel(
                id=m["id"],
                name=m["name"],
                backend=self.name,
                backend_model_id=m["id"],
                size_bytes=size,
                params_billion=params,
                quant="GGUF",
            ))
        return result

    # ── Resolution ────────────────────────────────────────────────────

    def _resolve_model_path(self, model_id: str) -> Path | None:
        """Match a UI model id back to a GGUF on disk.

        Mirrors :class:`LlamaCppClient._resolve_model_path` so existing
        saved selections keep working after the migration.
        """
        if os.path.isfile(model_id) and model_id.endswith(".gguf"):
            return Path(model_id)

        normalized = (
            model_id.replace(".gguf", "").replace(".bin", "").lower().replace(" ", "-")
        )

        for m in self._discovered:
            if m["id"] in (model_id, normalized):
                return Path(m["path"])

        for path in _find_gguf_files(self._models_dir):
            stem = _model_id_from_path(path)
            if stem in (model_id, normalized):
                return path

        for path in _find_gguf_files(self._models_dir):
            if _model_id_from_path(path).startswith(normalized):
                return path

        subdir = self._models_dir / model_id
        if subdir.is_dir():
            ggufs = list(subdir.glob("*.gguf"))
            if ggufs:
                return ggufs[0]

        return None

    async def _ensure_model_loaded(self, model_id: str) -> LlamaServerSidecar:
        path = self._resolve_model_path(model_id)
        if path is None:
            raise LlamaServerError(f"Model not found: {model_id}")
        sidecar = await self._get_sidecar()
        await sidecar.ensure_loaded(path)
        return sidecar

    # ── Streaming generation ──────────────────────────────────────────

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        try:
            sidecar = await self._ensure_model_loaded(model_id)
        except LlamaServerError as exc:
            logger.error("llama-server load failed: %s", exc)
            yield f"[Error: {exc}]", GenerationMetrics()
            return

        payload = self._build_payload(messages, kwargs, stream=True)

        t0 = time.perf_counter()
        ttft_ms = 0
        tokens = 0
        prompt_tokens = 0
        completion_tokens = 0

        try:
            async with sidecar.http() as client:
                async with client.stream(
                    "POST", "/v1/chat/completions", json=payload
                ) as resp:
                    resp.raise_for_status()
                    async for raw_line in resp.aiter_lines():
                        if not raw_line:
                            continue
                        if not raw_line.startswith("data:"):
                            continue
                        data = raw_line[5:].strip()
                        if data == "[DONE]":
                            break

                        try:
                            chunk = json.loads(data)
                        except json.JSONDecodeError:
                            continue

                        choices = chunk.get("choices") or []
                        if choices:
                            delta = choices[0].get("delta") or {}
                            content = delta.get("content")
                            if content:
                                if ttft_ms == 0:
                                    ttft_ms = int((time.perf_counter() - t0) * 1000)
                                tokens += 1
                                yield content, None

                            finish = choices[0].get("finish_reason")
                            if finish:
                                # Some llama-server versions send usage in the final chunk.
                                usage = chunk.get("usage") or {}
                                prompt_tokens = int(usage.get("prompt_tokens", 0))
                                completion_tokens = int(
                                    usage.get("completion_tokens", tokens)
                                )

                        # Other forks emit usage as a top-level field on
                        # the closing chunk with empty choices.
                        usage = chunk.get("usage")
                        if usage and not completion_tokens:
                            prompt_tokens = int(usage.get("prompt_tokens", 0))
                            completion_tokens = int(usage.get("completion_tokens", tokens))

        except httpx.HTTPError as exc:
            logger.exception("llama-server stream error")
            yield f"[Error: {exc}]", None

        elapsed_ms = (time.perf_counter() - t0) * 1000
        completion_tokens = completion_tokens or tokens
        tok_per_s = completion_tokens / max(elapsed_ms / 1000.0, 1e-3)

        yield "", GenerationMetrics(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=prompt_tokens + completion_tokens,
            ttft_ms=ttft_ms,
            tok_per_s=round(tok_per_s, 2),
            elapsed_ms=int(elapsed_ms),
        )

    # ── Non-streaming generation ──────────────────────────────────────

    async def generate(
        self,
        model_id: str,
        messages: list[dict[str, Any]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        try:
            sidecar = await self._ensure_model_loaded(model_id)
        except LlamaServerError as exc:
            return f"[Error: {exc}]", GenerationMetrics()

        payload = self._build_payload(messages, kwargs, stream=False)

        t0 = time.perf_counter()
        try:
            async with sidecar.http() as client:
                resp = await client.post("/v1/chat/completions", json=payload)
                resp.raise_for_status()
                data = resp.json()
        except httpx.HTTPError as exc:
            logger.exception("llama-server request failed")
            elapsed_ms = int((time.perf_counter() - t0) * 1000)
            return f"[Error: {exc}]", GenerationMetrics(elapsed_ms=elapsed_ms)

        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        text = (
            (data.get("choices") or [{}])[0].get("message", {}).get("content", "")
        )
        usage = data.get("usage") or {}
        prompt_tokens = int(usage.get("prompt_tokens", 0))
        completion_tokens = int(usage.get("completion_tokens", 0))
        tok_per_s = completion_tokens / max(elapsed_ms / 1000.0, 1e-3)

        return text, GenerationMetrics(
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
            total_tokens=prompt_tokens + completion_tokens,
            ttft_ms=elapsed_ms,  # non-streaming: TTFT ≈ elapsed
            tok_per_s=round(tok_per_s, 2),
            elapsed_ms=elapsed_ms,
        )

    # ── Embeddings (used by clara/compressor.py via embed_texts) ──────

    async def embed(self, texts: list[str]) -> list[list[float]]:
        """Return one embedding vector per input text.

        Uses the ``--embeddings`` flag on the sidecar so the same process
        serves chat and embeddings without doubling RAM. Caller must
        ensure a model has been loaded (via any prior chat request) —
        if no model is loaded yet, this raises :class:`LlamaServerError`.
        """
        sidecar = await self._get_sidecar()
        if not sidecar.is_running:
            raise LlamaServerError(
                "llama-server is not running — load a model first to enable embeddings."
            )
        async with sidecar.http(timeout=120.0) as client:
            resp = await client.post(
                "/v1/embeddings",
                json={"input": texts, "model": "embedding"},
            )
            resp.raise_for_status()
            data = resp.json()

        out: list[list[float]] = []
        for item in data.get("data") or []:
            vec = item.get("embedding") or []
            out.append([float(x) for x in vec])
        return out

    # ── Helpers ───────────────────────────────────────────────────────

    @staticmethod
    def _build_payload(
        messages: list[dict[str, Any]],
        kwargs: dict[str, Any],
        *,
        stream: bool,
    ) -> dict[str, Any]:
        return {
            "model": kwargs.get("backend_model_id") or "default",
            "messages": messages,
            "temperature": float(kwargs.get("temperature") or 0.7),
            "top_p": float(kwargs.get("top_p") or 0.9),
            "max_tokens": int(kwargs.get("max_tokens") or 2048),
            "stream": stream,
        }

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def close(self) -> None:
        # The sidecar is a process-wide singleton; the supervisor stops
        # it on app exit. Don't kill it here just because one client
        # goes out of scope.
        return None
