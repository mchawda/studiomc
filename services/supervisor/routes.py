"""Supervisor API routes.

Endpoints for managing child services, querying hardware info, and global search.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Query

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
