# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Supervisor API routes.

Endpoints for managing child services, querying hardware info, and global search.
"""

from __future__ import annotations

import hashlib
import secrets
import sys
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

sys.path.insert(0, str(Path(__file__).parent.parent))
from common.database import Database
from common.schemas import (
    HardwareInfo,
    SearchResponse,
    SearchResult,
    ServiceStatus,
    SupervisorStatus,
)

from supervisor.manager import ProcessManager

router = APIRouter()

# The manager instance is injected at app startup via `set_manager()`.
_manager: ProcessManager | None = None


def set_manager(mgr: ProcessManager) -> None:
    """Called once from app.py to wire the shared manager instance."""
    global _manager
    _manager = mgr


def _mgr() -> ProcessManager:
    if _manager is None:
        raise HTTPException(status_code=503, detail="Supervisor not initialised yet")
    return _manager


# ── Health ───────────────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "supervisor"}


# ── Service status ───────────────────────────────────────────────────────


@router.get("/status", response_model=SupervisorStatus)
async def status() -> SupervisorStatus:
    """Return the status of every managed service."""
    mgr = _mgr()
    return mgr.get_status()


# ── Start / Stop ─────────────────────────────────────────────────────────


@router.post("/start", response_model=list[ServiceStatus])
async def start_services(
    name: Optional[str] = Query(None, description="Service name, or omit to start all"),
) -> list[ServiceStatus]:
    """Start all services, or a single service by name."""
    mgr = _mgr()
    if name:
        st = await mgr.start_service(name)
        return [st]
    return await mgr.start_all()


@router.post("/stop", response_model=list[ServiceStatus])
async def stop_services(
    name: Optional[str] = Query(None, description="Service name, or omit to stop all"),
) -> list[ServiceStatus]:
    """Stop all services, or a single service by name."""
    mgr = _mgr()
    if name:
        st = await mgr.stop_service(name)
        return [st]
    return await mgr.stop_all()


@router.post("/restart/{service_name}", response_model=ServiceStatus)
async def restart_service(service_name: str) -> ServiceStatus:
    """Restart a specific service."""
    mgr = _mgr()
    try:
        return await mgr.restart_service(service_name)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


# ── Shutdown ─────────────────────────────────────────────────────────────


@router.post("/shutdown")
async def shutdown() -> dict[str, str]:
    """Gracefully stop all child services, then signal the supervisor to exit."""
    import asyncio
    import os
    import signal

    mgr = _mgr()
    await mgr.stop_all()

    async def _deferred_exit() -> None:
        await asyncio.sleep(0.5)
        os.kill(os.getpid(), signal.SIGTERM)

    asyncio.create_task(_deferred_exit())
    return {"status": "shutting_down"}


# ── Hardware ─────────────────────────────────────────────────────────────


@router.get("/hardware", response_model=HardwareInfo | None)
async def get_hardware() -> HardwareInfo | None:
    """Return cached hardware info (may be None if scan hasn't run yet)."""
    return _mgr().hw_info


@router.post("/hardware/scan", response_model=HardwareInfo)
async def scan_hardware() -> HardwareInfo:
    """Force a fresh hardware scan (including disk benchmark)."""
    return await _mgr().scan_hardware(quick=False)


# ── Global search ────────────────────────────────────────────────────


@router.get("/search", response_model=SearchResponse)
async def search(
    q: str = Query(..., min_length=1, description="Search query"),
    scope: str = Query("all", description="Search scope: chats, docs, or all"),
    limit: int = Query(20, ge=1, le=100, description="Max results to return"),
) -> SearchResponse:
    """Search across chats and documents using simple LIKE matching.

    Parameters
    ----------
    q : str
        The search query.
    scope : str
        ``"chats"`` — only chat messages, ``"docs"`` — only documents,
        ``"all"`` — both.
    limit : int
        Maximum number of results (default 20).
    """

    db = await Database.instance()
    pattern = f"%{q}%"
    results: list[SearchResult] = []

    # ── Search chat messages ────────────────────────────────────
    if scope in ("chats", "all"):
        rows = await db.fetchall(
            """
            SELECT m.id, m.chat_id, m.content, m.created_at,
                   c.title AS chat_title
            FROM messages m
            LEFT JOIN chats c ON c.id = m.chat_id
            WHERE m.content LIKE ? AND m.role IN ('user', 'assistant')
            ORDER BY m.created_at DESC
            LIMIT ?
            """,
            (pattern, limit),
        )
        for row in rows:
            content = row["content"] or ""
            # Build a short snippet around the match
            lower_content = content.lower()
            match_pos = lower_content.find(q.lower())
            if match_pos >= 0:
                start = max(0, match_pos - 40)
                end = min(len(content), match_pos + len(q) + 60)
                snippet = ("..." if start > 0 else "") + content[start:end] + ("..." if end < len(content) else "")
            else:
                snippet = content[:100] + ("..." if len(content) > 100 else "")

            results.append(
                SearchResult(
                    type="chat",
                    id=row["chat_id"] or row["id"],
                    title=row["chat_title"] or "Untitled Chat",
                    snippet=snippet.strip(),
                    timestamp=row["created_at"] or "",
                )
            )

    # ── Search documents ────────────────────────────────────────
    if scope in ("docs", "all"):
        rows = await db.fetchall(
            """
            SELECT id, filename, created_at
            FROM documents
            WHERE filename LIKE ?
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (pattern, limit),
        )
        for row in rows:
            results.append(
                SearchResult(
                    type="document",
                    id=row["id"],
                    title=row["filename"] or "Untitled",
                    snippet=f"Document: {row['filename']}",
                    timestamp=row["created_at"] or "",
                )
            )

        # Also search doc_chunks text content
        chunk_rows = await db.fetchall(
            """
            SELECT dc.document_id, dc.text, dc.chunk_index, d.filename, d.created_at
            FROM doc_chunks dc
            LEFT JOIN documents d ON d.id = dc.document_id
            WHERE dc.text LIKE ?
            ORDER BY d.created_at DESC
            LIMIT ?
            """,
            (pattern, limit),
        )
        seen_doc_ids = {r.id for r in results if r.type == "document"}
        for row in chunk_rows:
            doc_id = row["document_id"]
            if doc_id in seen_doc_ids:
                continue
            seen_doc_ids.add(doc_id)

            text = row["text"] or ""
            lower_text = text.lower()
            match_pos = lower_text.find(q.lower())
            if match_pos >= 0:
                start = max(0, match_pos - 40)
                end = min(len(text), match_pos + len(q) + 60)
                snippet = ("..." if start > 0 else "") + text[start:end] + ("..." if end < len(text) else "")
            else:
                snippet = text[:100] + ("..." if len(text) > 100 else "")

            results.append(
                SearchResult(
                    type="document",
                    id=doc_id,
                    title=row["filename"] or "Untitled",
                    snippet=snippet.strip(),
                    timestamp=row["created_at"] or "",
                )
            )

    # De-duplicate and trim to limit
    results = results[:limit]

    return SearchResponse(query=q, results=results, total=len(results))


# ── API Key Management ───────────────────────────────────────────────


def _hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


class CreateApiKeyRequest(BaseModel):
    name: str = "Default"


@router.post("/api-keys")
async def create_api_key(req: CreateApiKeyRequest) -> dict:
    """Generate a new API key for external tool access (Cursor, Claude Code, etc.)."""
    db = await Database.instance()
    raw_key = f"sk-studiomc-{secrets.token_urlsafe(32)}"
    key_id = secrets.token_urlsafe(8)
    prefix = raw_key[:20] + "..."

    await db.execute(
        "INSERT INTO api_keys (id, name, key_hash, prefix, created_at) VALUES (?, ?, ?, ?, datetime('now'))",
        (key_id, req.name, _hash_key(raw_key), prefix),
    )
    await db.commit()

    return {
        "id": key_id,
        "name": req.name,
        "key": raw_key,
        "prefix": prefix,
        "message": "Save this key — it won't be shown again.",
    }


@router.get("/api-keys")
async def list_api_keys() -> dict:
    """List all API keys (shows prefix only, not the full key)."""
    db = await Database.instance()
    rows = await db.fetchall(
        "SELECT id, name, prefix, created_at, last_used_at, revoked FROM api_keys ORDER BY created_at DESC"
    )
    keys = []
    for row in rows:
        keys.append({
            "id": row["id"],
            "name": row["name"],
            "prefix": row["prefix"],
            "created_at": row["created_at"],
            "last_used_at": row["last_used_at"],
            "revoked": bool(row["revoked"]),
        })
    return {"keys": keys}


@router.delete("/api-keys/{key_id}")
async def revoke_api_key(key_id: str) -> dict:
    """Revoke an API key."""
    db = await Database.instance()
    row = await db.fetchone("SELECT id FROM api_keys WHERE id = ?", (key_id,))
    if not row:
        raise HTTPException(status_code=404, detail="Key not found")
    await db.execute("UPDATE api_keys SET revoked = 1 WHERE id = ?", (key_id,))
    await db.commit()
    return {"status": "revoked", "id": key_id}


@router.post("/api-keys/verify")
async def verify_api_key(key: str = Query(..., description="The full API key to verify")) -> dict:
    """Verify an API key is valid (used by inference middleware)."""
    db = await Database.instance()
    row = await db.fetchone(
        "SELECT id, name, revoked FROM api_keys WHERE key_hash = ?",
        (_hash_key(key),),
    )
    if not row:
        return {"valid": False, "reason": "unknown_key"}
    if row["revoked"]:
        return {"valid": False, "reason": "revoked"}
    await db.execute(
        "UPDATE api_keys SET last_used_at = datetime('now') WHERE id = ?",
        (row["id"],),
    )
    await db.commit()
    return {"valid": True, "key_id": row["id"], "name": row["name"]}
