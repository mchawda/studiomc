# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""API routes for the Inference Service.

Endpoints:
    POST /v1/chat/completions  — OpenAI-compatible chat completions (streaming + non-streaming)
    WS   /v1/chat/stream       — WebSocket streaming for Flutter UI
    GET  /v1/models            — merged model list from all backends
    POST /v1/models/select     — set active model + backend for inference
    GET  /v1/backends          — list discovered backends and their status
    POST /v1/backends/probe    — re-scan for local backends
    GET  /health               — health check
"""

from __future__ import annotations

import json
import logging
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from fastapi import APIRouter, HTTPException, Request, WebSocket
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

from common.schemas import (
    AIModel,
    InferenceProfile,
    ChatCompletionChoice,
    ChatCompletionRequest,
    ChatCompletionResponse,
    SearchResult,
    SearchResponse,
)
from common.database import Database

from inference.engine import GenerationMetrics, InferenceEngine
from inference.router import InferenceRouter
from inference.streaming import sse_generate, websocket_stream_handler

logger = logging.getLogger("inference.routes")

# ── Router ────────────────────────────────────────────────────────────

router = APIRouter()

# The inference router is set by app.py at startup via `set_router()`
_inference_router: InferenceRouter | None = None

# Keep backward compat — engine is also available via the router
_engine: InferenceEngine | None = None


def set_router(inference_router: InferenceRouter) -> None:
    """Inject the InferenceRouter instance (called once from app.py)."""
    global _inference_router, _engine
    _inference_router = inference_router
    _engine = inference_router.engine


def set_engine(engine: InferenceEngine) -> None:
    """Legacy — inject the engine instance (backward compat)."""
    global _engine
    _engine = engine


def get_router() -> InferenceRouter:
    if _inference_router is None:
        raise RuntimeError("InferenceRouter not initialized")
    return _inference_router


def get_engine() -> InferenceEngine:
    if _engine is None:
        raise RuntimeError("Engine not initialized")
    return _engine


# ── Health ────────────────────────────────────────────────────────────

@router.get("/health")
async def health() -> dict[str, Any]:
    ir = get_router()
    engine = ir.engine
    backends = ir.get_backend_status()
    online_backends = [n for n, info in backends.items() if info.online]
    return {
        "status": "ok",
        "service": "inference",
        "model_loaded": ir.is_ready,
        "active_model": ir.active_model_id,
        "active_backend": ir.active_backend_name,
        "engine": "studiomc",
        "online_backends": online_backends,
        "timestamp": datetime.utcnow().isoformat(),
    }


# ── Backends ─────────────────────────────────────────────────────────

@router.get("/v1/backends")
async def list_backends() -> dict[str, Any]:
    """List discovered backends and their status."""
    ir = get_router()
    statuses = ir.get_backend_status()
    backends = []
    for name, info in statuses.items():
        backends.append({
            "name": info.name,
            "url": info.url,
            "online": info.online,
            "model_count": len(info.models),
            "error": info.error,
        })
    return {
        "backends": backends,
        "active_backend": ir.active_backend_name,
        "active_model": ir.active_model_id,
    }


@router.post("/v1/backends/probe")
async def probe_backends() -> dict[str, Any]:
    """Re-scan for local backends (Ollama, LM Studio, etc.)."""
    ir = get_router()
    results = await ir.probe_backends()
    backends = []
    for name, info in results.items():
        backends.append({
            "name": info.name,
            "url": info.url,
            "online": info.online,
            "model_count": len(info.models),
            "error": info.error,
        })
    return {"backends": backends}


# ── List models (merged from all backends) ───────────────────────────

@router.get("/v1/models")
async def list_models() -> dict[str, Any]:
    """Return merged model list from all online backends.

    Returns both backend models (Ollama, LM Studio, etc.) and
    locally registered models from the database.
    """
    ir = get_router()

    # Get unified models from all backends
    unified_models = await ir.list_all_models()

    # Also get locally registered models from the DB
    db_models: list[dict[str, Any]] = []
    try:
        db = await Database.instance()
        rows = await db.fetchall(
            "SELECT id, name, source, params_billion, quant, disk_bytes, arch, "
            "context_max, created_at, last_used_at FROM models ORDER BY name"
        )
        for row in rows:
            db_models.append({
                "id": row["id"],
                "object": "model",
                "owned_by": "local",
                "backend": "studiomc",
                "name": row["name"],
                "source": row["source"],
                "params_billion": row["params_billion"],
                "quant": row["quant"],
                "disk_bytes": row["disk_bytes"],
                "arch": row["arch"],
                "context_max": row["context_max"],
                "created_at": row["created_at"],
                "last_used_at": row["last_used_at"],
            })
    except Exception:
        logger.debug("Could not query local model database")

    # Convert unified models to OpenAI-compatible format
    backend_models: list[dict[str, Any]] = []
    for m in unified_models:
        backend_models.append({
            "id": m.id,
            "object": "model",
            "owned_by": m.backend,
            "backend": m.backend,
            "name": m.name,
            "backend_model_id": m.backend_model_id,
            "size_bytes": m.size_bytes,
            "params_billion": m.params_billion,
            "quant": m.quant,
            "arch": m.arch,
            "context_length": m.context_length,
        })

    return {
        "object": "list",
        "data": backend_models + db_models,
        "active_model": ir.active_model_id,
        "active_backend": ir.active_backend_name,
    }


# ── Select model ──────────────────────────────────────────────────────

class ModelSelectRequest(BaseModel):
    model_id: str
    backend: str | None = None  # optional: force a specific backend


@router.post("/v1/models/select")
async def select_model(req: ModelSelectRequest) -> dict[str, Any]:
    """Set the active model for inference, routing through InferenceRouter."""
    ir = get_router()

    try:
        # For local models (not prefixed with a known external backend),
        # look up the model in the DB and resolve its filesystem path.
        if not req.backend or req.backend in ("studiomc", "llamacpp"):
            if not any(
                req.model_id.startswith(p)
                for p in ("ollama/", "lmstudio/", "frontier:")
            ):
                try:
                    from common.config import MODELS_DIR

                    db = await Database.instance()
                    row = await db.fetchone(
                        "SELECT id, name, source_ref FROM models WHERE id = ?",
                        (req.model_id,),
                    )
                    if row:
                        # Check if a GGUF file exists for this model → use llamacpp
                        model_dir = MODELS_DIR / req.model_id
                        gguf_files = list(model_dir.glob("*.gguf")) if model_dir.is_dir() else []
                        if gguf_files:
                            # Route to llamacpp backend
                            req.backend = "llamacpp"
                        else:
                            # Fallback to SpliceLLM for safetensors
                            model_path = row["source_ref"] or req.model_id
                            await ir.engine.load_model(req.model_id, model_path)

                        # Update last_used_at
                        await db.execute(
                            "UPDATE models SET last_used_at = datetime('now') WHERE id = ?",
                            (req.model_id,),
                        )
                        await db.commit()
                except Exception:
                    logger.debug("DB lookup for model %s skipped", req.model_id)

        result = await ir.select_model(req.model_id, backend=req.backend)

        return {
            "status": "ok",
            "active_model": result["model_id"],
            "backend": result["backend"],
            "backend_model_id": result["backend_model_id"],
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Failed to select model %s", req.model_id)
        raise HTTPException(status_code=500, detail=str(e))


# ── Chat completions ─────────────────────────────────────────────────

@router.post("/v1/chat/completions")
async def chat_completions(req: ChatCompletionRequest, request: Request):
    """OpenAI-compatible chat completion endpoint.

    Routes through InferenceRouter to the active backend.
    Supports both streaming (SSE) and non-streaming responses.

    Extension headers:
        x-inference-profile: fast | balanced | quality
        x-inference-slowmode: true | false
    """
    ir = get_router()

    if not ir.is_ready:
        raise HTTPException(
            status_code=503,
            detail="No model selected. POST /v1/models/select first.",
        )

    # Read extension headers (fallback to body fields)
    profile = (
        request.headers.get("x-inference-profile")
        or request.headers.get("x-airllm-profile")  # backward compat
        or req.x_inference_profile.value
    )
    slowmode_header = (
        request.headers.get("x-inference-slowmode", "")
        or request.headers.get("x-airllm-slowmode", "")  # backward compat
    ).lower()
    slowmode = slowmode_header == "true" or req.x_inference_slowmode

    model_name = req.model or ir.active_model_id or "unknown"

    gen_kwargs: dict[str, Any] = {
        "profile": profile,
        "temperature": req.temperature,
        "max_tokens": req.max_tokens,
        "slowmode": slowmode,
    }

    if req.stream:
        return StreamingResponse(
            sse_generate(
                ir,
                req.messages,
                model_name,
                **gen_kwargs,
            ),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "X-Accel-Buffering": "no",
            },
        )

    # Non-streaming
    try:
        text, metrics = await ir.generate(
            req.messages,
            **gen_kwargs,
        )

        completion_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        response = ChatCompletionResponse(
            id=completion_id,
            created=int(time.time()),
            model=model_name,
            choices=[
                ChatCompletionChoice(
                    index=0,
                    message={"role": "assistant", "content": text},
                    finish_reason="stop",
                )
            ],
            usage={
                "prompt_tokens": metrics.prompt_tokens,
                "completion_tokens": metrics.completion_tokens,
                "total_tokens": metrics.total_tokens,
            },
        )

        # Record to database
        await _record_to_db(req.messages, text, metrics)

        resp = response.model_dump()
        resp["x_inference_metrics"] = {
            "ttft_ms": metrics.ttft_ms,
            "tok_per_s": round(metrics.tok_per_s, 2),
            "elapsed_ms": metrics.elapsed_ms,
            "backend": ir.active_backend_name,
        }
        return JSONResponse(content=resp)

    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        logger.exception("Chat completion error")
        raise HTTPException(status_code=500, detail=str(e))


# ── WebSocket streaming ──────────────────────────────────────────────

@router.websocket("/v1/chat/stream")
async def ws_chat_stream(websocket: WebSocket):
    """WebSocket endpoint for token-by-token streaming to Flutter UI."""
    ir = get_router()
    await websocket_stream_handler(
        websocket, ir, db_record_fn=_record_ws_to_db
    )


# ── Search ────────────────────────────────────────────────────────────

@router.get("/v1/search")
async def search_messages(q: str, limit: int = 50) -> SearchResponse:
    """Search chat messages by content using SQL LIKE.

    Returns matching messages with their parent chat title and timestamp.
    """
    if not q or not q.strip():
        return SearchResponse(query=q, results=[], total=0)

    db = await Database.instance()
    search_term = f"%{q.strip()}%"

    rows = await db.fetchall(
        """SELECT m.id, m.chat_id, m.role, m.content, m.created_at,
                  c.title AS chat_title
           FROM messages m
           LEFT JOIN chats c ON c.id = m.chat_id
           WHERE m.content LIKE ?
           ORDER BY m.created_at DESC
           LIMIT ?""",
        (search_term, limit),
    )

    results: list[SearchResult] = []
    for row in rows:
        content = row["content"] or ""
        # Build a snippet: find the match position and show surrounding context
        lower_content = content.lower()
        match_pos = lower_content.find(q.strip().lower())
        if match_pos >= 0:
            start = max(0, match_pos - 40)
            end = min(len(content), match_pos + len(q) + 60)
            snippet = ("…" if start > 0 else "") + content[start:end] + ("…" if end < len(content) else "")
        else:
            snippet = content[:100] + ("…" if len(content) > 100 else "")

        results.append(SearchResult(
            type="chat",
            id=row["chat_id"] or row["id"],
            title=row["chat_title"] or f"{row['role']} message",
            snippet=snippet.strip(),
            timestamp=row["created_at"] or "",
        ))

    return SearchResponse(query=q, results=results, total=len(results))


# ── Database recording helpers ────────────────────────────────────────

async def _record_to_db(
    messages: list[dict[str, Any]],
    response: str,
    metrics: GenerationMetrics,
) -> None:
    """Record a chat exchange to the database."""
    try:
        db = await Database.instance()
        ir = _inference_router

        chat_id = str(uuid.uuid4())
        now = datetime.utcnow().isoformat()

        first_user = next(
            (m["content"][:80] for m in messages if m.get("role") == "user"),
            "New Chat",
        )

        active_model = ir.active_model_id if ir else None
        await db.execute(
            "INSERT INTO chats (id, title, model_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (chat_id, first_user, active_model, now, now),
        )

        parent_id: str | None = None
        for msg in messages:
            msg_id = str(uuid.uuid4())
            await db.execute(
                "INSERT INTO messages (id, chat_id, role, content, parent_message_id, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (msg_id, chat_id, msg.get("role", "user"), msg.get("content", ""), parent_id, now),
            )
            parent_id = msg_id

        assistant_id = str(uuid.uuid4())
        await db.execute(
            "INSERT INTO messages (id, chat_id, role, content, tokens, parent_message_id, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (assistant_id, chat_id, "assistant", response, metrics.completion_tokens, parent_id, now),
        )

        await db.commit()
    except Exception:
        logger.exception("Failed to record chat to database")


async def _record_ws_to_db(
    *,
    chat_id: str,
    messages: list[dict[str, Any]],
    response: str,
    metrics: GenerationMetrics | None,
) -> None:
    """Record a WebSocket chat exchange to the database."""
    try:
        db = await Database.instance()
        ir = _inference_router
        now = datetime.utcnow().isoformat()

        existing = await db.fetchone("SELECT id FROM chats WHERE id = ?", (chat_id,))
        if not existing:
            first_user = next(
                (m["content"][:80] for m in messages if m.get("role") == "user"),
                "New Chat",
            )
            active_model = ir.active_model_id if ir else None
            await db.execute(
                "INSERT INTO chats (id, title, model_id, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (chat_id, first_user, active_model, now, now),
            )
        else:
            await db.execute(
                "UPDATE chats SET updated_at = ? WHERE id = ?",
                (now, chat_id),
            )

        parent_id: str | None = None
        user_msgs = [m for m in messages if m.get("role") == "user"]
        if user_msgs:
            last_user = user_msgs[-1]
            msg_id = str(uuid.uuid4())
            await db.execute(
                "INSERT INTO messages (id, chat_id, role, content, parent_message_id, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (msg_id, chat_id, "user", last_user.get("content", ""), parent_id, now),
            )
            parent_id = msg_id

        assistant_id = str(uuid.uuid4())
        tokens = metrics.completion_tokens if metrics else None
        await db.execute(
            "INSERT INTO messages (id, chat_id, role, content, tokens, parent_message_id, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (assistant_id, chat_id, "assistant", response, tokens, parent_id, now),
        )

        await db.commit()
    except Exception:
        logger.exception("Failed to record WS chat to database")
