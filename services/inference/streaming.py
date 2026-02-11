# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""WebSocket streaming for Flutter UI and SSE helpers.

Provides:
- WebSocket handler that streams token-by-token to connected Flutter clients.
- SSE (Server-Sent Events) helpers for OpenAI-compatible streaming responses.

Works with both the InferenceEngine directly and the InferenceRouter.
"""

from __future__ import annotations

import asyncio
import json
import logging
import sys
import time
import uuid
from pathlib import Path
from typing import Any, AsyncIterator, Protocol, runtime_checkable

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from fastapi import WebSocket, WebSocketDisconnect
from starlette.websockets import WebSocketState

from inference.engine import GenerationMetrics, InferenceEngine

logger = logging.getLogger("inference.streaming")


# ── Protocol for anything that can generate_stream ───────────────────

@runtime_checkable
class StreamGenerator(Protocol):
    """Anything with generate_stream(messages, **kwargs) -> AsyncIterator."""

    async def generate_stream(
        self,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        ...


# ── SSE helpers (for POST /v1/chat/completions?stream=true) ──────────

def sse_chunk(
    data: dict[str, Any],
    event: str | None = None,
) -> str:
    """Format a single SSE chunk string."""
    lines: list[str] = []
    if event:
        lines.append(f"event: {event}")
    lines.append(f"data: {json.dumps(data)}")
    lines.append("")
    lines.append("")
    return "\n".join(lines)


def make_stream_chunk(
    completion_id: str,
    model: str,
    token: str,
    finish_reason: str | None = None,
    created: int | None = None,
) -> dict[str, Any]:
    """Build an OpenAI-compatible streaming chunk."""
    delta: dict[str, str] = {}
    if token:
        delta["content"] = token

    choice: dict[str, Any] = {
        "index": 0,
        "delta": delta,
    }
    if finish_reason:
        choice["finish_reason"] = finish_reason

    return {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": created or int(time.time()),
        "model": model,
        "choices": [choice],
    }


async def sse_generate(
    generator: StreamGenerator,
    messages: list[dict[str, str]],
    model_name: str,
    *,
    profile: str = "balanced",
    temperature: float | None = None,
    max_tokens: int | None = None,
    slowmode: bool = False,
) -> AsyncIterator[str]:
    """Async generator that yields SSE-formatted strings for streaming.

    Works with both InferenceEngine and InferenceRouter.
    """
    completion_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
    created = int(time.time())
    metrics: GenerationMetrics | None = None

    # First chunk: role
    first_chunk = make_stream_chunk(
        completion_id, model_name, "", created=created
    )
    first_chunk["choices"][0]["delta"] = {"role": "assistant", "content": ""}
    yield sse_chunk(first_chunk)

    async for token, m in generator.generate_stream(
        messages,
        profile=profile,
        temperature=temperature,
        max_tokens=max_tokens,
        slowmode=slowmode,
    ):
        if m is not None:
            metrics = m
            continue
        chunk = make_stream_chunk(completion_id, model_name, token, created=created)
        yield sse_chunk(chunk)

    # Final chunk with finish_reason
    final = make_stream_chunk(
        completion_id, model_name, "", finish_reason="stop", created=created
    )
    if metrics:
        final["usage"] = {
            "prompt_tokens": metrics.prompt_tokens,
            "completion_tokens": metrics.completion_tokens,
            "total_tokens": metrics.total_tokens,
        }
        final["x_inference_metrics"] = {
            "ttft_ms": metrics.ttft_ms,
            "tok_per_s": round(metrics.tok_per_s, 2),
            "elapsed_ms": metrics.elapsed_ms,
        }
    yield sse_chunk(final)

    # SSE terminator
    yield "data: [DONE]\n\n"


# ── WebSocket handler (for WS /v1/chat/stream) ──────────────────────

async def websocket_stream_handler(
    websocket: WebSocket,
    generator: StreamGenerator,
    db_record_fn: Any | None = None,
) -> None:
    """Handle a single WebSocket connection for token streaming.

    Works with both InferenceEngine and InferenceRouter.

    Protocol:
        Client sends JSON:
            {
                "chat_id": "...",
                "messages": [...],
                "model": "ollama/llama3.2:3b",   (optional)
                "backend": "ollama",              (optional)
                "profile": "balanced",
                "temperature": 0.7,
                "max_tokens": 1024,
                "slowmode": false
            }

        Server sends JSON frames:
            {"type": "token",  "content": "Hello"}
            {"type": "token",  "content": " world"}
            ...
            {"type": "done",   "metrics": {...}}

        On error:
            {"type": "error",  "message": "..."}
    """
    await websocket.accept()
    logger.info("WebSocket client connected")

    # Import here to avoid circular imports
    from inference.router import InferenceRouter

    try:
        while True:
            raw = await websocket.receive_text()
            try:
                request = json.loads(raw)
            except json.JSONDecodeError:
                await _ws_send(websocket, {
                    "type": "error",
                    "message": "Invalid JSON",
                })
                continue

            messages = request.get("messages", [])
            if not messages:
                await _ws_send(websocket, {
                    "type": "error",
                    "message": "No messages provided",
                })
                continue

            chat_id = request.get("chat_id")
            profile = request.get("profile", "balanced")
            temperature = request.get("temperature")
            max_tokens = request.get("max_tokens")
            slowmode = request.get("slowmode", False)

            # If the generator is an InferenceRouter, handle model selection
            if isinstance(generator, InferenceRouter):
                model = request.get("model")
                backend = request.get("backend")
                if model:
                    try:
                        await generator.select_model(model, backend=backend)
                    except Exception as e:
                        await _ws_send(websocket, {
                            "type": "error",
                            "message": f"Failed to select model: {e}",
                        })
                        continue

                if not generator.is_ready:
                    await _ws_send(websocket, {
                        "type": "error",
                        "message": "No model selected. Send 'model' field or POST /v1/models/select first.",
                    })
                    continue
            else:
                # Legacy InferenceEngine path
                if isinstance(generator, InferenceEngine) and not generator.is_loaded:
                    await _ws_send(websocket, {
                        "type": "error",
                        "message": "No model loaded",
                    })
                    continue

            # Stream tokens
            collected_tokens: list[str] = []
            metrics: GenerationMetrics | None = None

            try:
                async for token, m in generator.generate_stream(
                    messages,
                    profile=profile,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    slowmode=slowmode,
                ):
                    if m is not None:
                        metrics = m
                        continue
                    collected_tokens.append(token)
                    await _ws_send(websocket, {
                        "type": "token",
                        "content": token,
                    })

                # Send completion
                done_payload: dict[str, Any] = {"type": "done"}
                if metrics:
                    done_payload["metrics"] = {
                        "ttft_ms": metrics.ttft_ms,
                        "tok_per_s": round(metrics.tok_per_s, 2),
                        "elapsed_ms": metrics.elapsed_ms,
                        "total_tokens": metrics.total_tokens,
                        "prompt_tokens": metrics.prompt_tokens,
                        "completion_tokens": metrics.completion_tokens,
                    }

                # Add backend info if available
                if isinstance(generator, InferenceRouter):
                    done_payload["backend"] = generator.active_backend_name

                await _ws_send(websocket, done_payload)

                # Record to database if callback provided
                if db_record_fn and chat_id:
                    full_response = "".join(collected_tokens)
                    try:
                        await db_record_fn(
                            chat_id=chat_id,
                            messages=messages,
                            response=full_response,
                            metrics=metrics,
                        )
                    except Exception:
                        logger.exception("Failed to record message to DB")

            except RuntimeError as e:
                await _ws_send(websocket, {
                    "type": "error",
                    "message": str(e),
                })

    except WebSocketDisconnect:
        logger.info("WebSocket client disconnected")
    except Exception:
        logger.exception("WebSocket handler error")
        if websocket.client_state == WebSocketState.CONNECTED:
            await websocket.close(code=1011, reason="Internal error")


async def _ws_send(websocket: WebSocket, data: dict[str, Any]) -> None:
    """Send JSON over WebSocket, silently ignoring send errors."""
    try:
        if websocket.client_state == WebSocketState.CONNECTED:
            await websocket.send_json(data)
    except Exception:
        logger.debug("Failed to send WS message (client may have disconnected)")
