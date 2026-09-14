# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""HTTP API for the Studiomc Memory service.

* ``GET    /v1/memories``                  — list memories (filter by scope)
* ``POST   /v1/memories``                  — manually add a memory
* ``GET    /v1/memories/{id}``             — single memory
* ``PATCH  /v1/memories/{id}``             — edit fields, pin/unpin
* ``DELETE /v1/memories/{id}``             — remove
* ``DELETE /v1/memories``                  — clear (optionally by scope)
* ``POST   /v1/memories/extract``          — run LLM extractor on a turn
* ``POST   /v1/memories/relevant``         — query relevant memories
* ``POST   /v1/memories/format``           — render context block for prompt
"""

from __future__ import annotations

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from memory.extractor import extract_memories
from memory.store import (
    add_memory,
    clear_memories,
    delete_memory,
    format_for_prompt,
    get_memory,
    list_memories,
    relevant_memories,
    update_memory,
)

logger = logging.getLogger("memory.routes")
router = APIRouter()


# ── Schemas ──────────────────────────────────────────────────────────


class MemoryIn(BaseModel):
    content: str = Field(..., min_length=1, max_length=2000)
    scope: str = Field("global", pattern="^(global|chat|project)$")
    scope_id: Optional[str] = None
    key: Optional[str] = Field(None, max_length=40)
    tags: list[str] = Field(default_factory=list)
    pinned: bool = False
    confidence: float = Field(1.0, ge=0.0, le=1.0)
    source_message_id: Optional[str] = None


class MemoryPatch(BaseModel):
    content: Optional[str] = None
    key: Optional[str] = None
    tags: Optional[list[str]] = None
    pinned: Optional[bool] = None
    confidence: Optional[float] = Field(None, ge=0.0, le=1.0)


class ExtractIn(BaseModel):
    user_message: str
    assistant_message: str
    chat_id: Optional[str] = None
    auto_save: bool = True


class RelevantIn(BaseModel):
    query: str
    scope_id: Optional[str] = None
    limit: int = Field(8, ge=1, le=32)


class FormatIn(BaseModel):
    query: Optional[str] = None
    scope_id: Optional[str] = None
    limit: int = Field(8, ge=1, le=32)
    memory_ids: Optional[list[str]] = None


class ApiResponse(BaseModel):
    success: bool = True
    data: Any = None
    error: Optional[dict[str, Any]] = None


def ok(data: Any = None) -> ApiResponse:
    return ApiResponse(success=True, data=data)


def http_err(message: str, code: str = "error", status: int = 400) -> HTTPException:
    return HTTPException(
        status_code=status,
        detail={"success": False, "data": None, "error": {"code": code, "message": message}},
    )


# ── Health ───────────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "memory"}


# ── CRUD ─────────────────────────────────────────────────────────────


@router.get("/v1/memories", response_model=ApiResponse)
async def list_route(
    scope: Optional[str] = None,
    scope_id: Optional[str] = None,
    limit: int = 200,
) -> ApiResponse:
    memories = await list_memories(scope=scope, scope_id=scope_id, limit=limit)
    return ok([m.to_dict() for m in memories])


@router.post("/v1/memories", response_model=ApiResponse)
async def add_route(payload: MemoryIn) -> ApiResponse:
    try:
        mem = await add_memory(
            content=payload.content,
            scope=payload.scope,
            scope_id=payload.scope_id,
            key=payload.key,
            tags=payload.tags,
            pinned=payload.pinned,
            confidence=payload.confidence,
            source_message_id=payload.source_message_id,
        )
    except ValueError as exc:
        raise http_err(str(exc), "validation_error", 422) from exc
    return ok(mem.to_dict())


@router.get("/v1/memories/{memory_id}", response_model=ApiResponse)
async def get_route(memory_id: str) -> ApiResponse:
    mem = await get_memory(memory_id)
    if mem is None:
        raise http_err("memory not found", "not_found", 404)
    return ok(mem.to_dict())


@router.patch("/v1/memories/{memory_id}", response_model=ApiResponse)
async def patch_route(memory_id: str, payload: MemoryPatch) -> ApiResponse:
    body = payload.model_dump(exclude_unset=True)
    try:
        mem = await update_memory(memory_id, **body)
    except KeyError as exc:
        raise http_err("memory not found", "not_found", 404) from exc
    except ValueError as exc:
        raise http_err(str(exc), "validation_error", 422) from exc
    return ok(mem.to_dict())


@router.delete("/v1/memories/{memory_id}", response_model=ApiResponse)
async def delete_route(memory_id: str) -> ApiResponse:
    removed = await delete_memory(memory_id)
    if not removed:
        raise http_err("memory not found", "not_found", 404)
    return ok({"id": memory_id, "removed": True})


@router.delete("/v1/memories", response_model=ApiResponse)
async def clear_route(scope: Optional[str] = None) -> ApiResponse:
    count = await clear_memories(scope=scope)
    return ok({"removed": count})


# ── Extraction & retrieval ───────────────────────────────────────────


@router.post("/v1/memories/extract", response_model=ApiResponse)
async def extract_route(payload: ExtractIn) -> ApiResponse:
    candidates = await extract_memories(payload.user_message, payload.assistant_message)
    saved: list[dict[str, Any]] = []
    if payload.auto_save:
        for cand in candidates:
            try:
                mem = await add_memory(
                    content=cand["content"],
                    key=cand.get("key"),
                    tags=cand.get("tags") or [],
                    confidence=float(cand.get("confidence", 0.6)),
                    scope_id=payload.chat_id,
                    scope="chat" if payload.chat_id else "global",
                )
                saved.append(mem.to_dict())
            except ValueError:
                continue
    return ok({"candidates": candidates, "saved": saved})


@router.post("/v1/memories/relevant", response_model=ApiResponse)
async def relevant_route(payload: RelevantIn) -> ApiResponse:
    memories = await relevant_memories(
        query=payload.query,
        scope_id=payload.scope_id,
        limit=payload.limit,
    )
    return ok([m.to_dict() for m in memories])


@router.post("/v1/memories/format", response_model=ApiResponse)
async def format_route(payload: FormatIn) -> ApiResponse:
    if payload.memory_ids:
        memories = []
        for mid in payload.memory_ids:
            mem = await get_memory(mid)
            if mem is not None:
                memories.append(mem)
    else:
        query = payload.query or ""
        memories = await relevant_memories(
            query=query,
            scope_id=payload.scope_id,
            limit=payload.limit,
        )
    return ok({"text": format_for_prompt(memories), "count": len(memories)})
