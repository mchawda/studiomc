"""API routes for the Recursive Orchestrator Service.

Endpoints
---------
POST /reasoning/run      — Execute a reasoning run
GET  /reasoning/runs/{chat_id} — Get reasoning runs for a chat
GET  /health             — Health check
"""

from __future__ import annotations

import json
import logging

from fastapi import APIRouter, HTTPException

from common.database import Database
from common.schemas import (
    Citation,
    ReasoningRequest,
    ReasoningResponse,
    TraceStep,
)

from orchestrator.reasoning import run_reasoning

logger = logging.getLogger("orchestrator.routes")

router = APIRouter()


# ── Health check ────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict:
    """Simple liveness probe."""
    return {"status": "ok", "service": "orchestrator"}


# ── Reasoning run ───────────────────────────────────────────────────


@router.post("/reasoning/run", response_model=ReasoningResponse)
async def reasoning_run(request: ReasoningRequest) -> ReasoningResponse:
    """Execute a full reasoning run (plan → tool → observe → answer).

    Returns the answer, citations, execution trace, metrics, and an
    optional ``stopped_reason`` if a budget was exceeded.
    """

    logger.info(
        "Reasoning run: chat_id=%s mode=%s query=%.80s",
        request.chat_id,
        request.mode.value,
        request.user_query,
    )

    try:
        response = await run_reasoning(request)
    except Exception:
        logger.exception("Reasoning run failed for chat_id=%s", request.chat_id)
        raise HTTPException(status_code=500, detail="Reasoning run failed")

    return response


# ── Get reasoning runs for a chat ───────────────────────────────────


@router.get("/reasoning/runs/{chat_id}")
async def get_reasoning_runs(chat_id: str) -> list[dict]:
    """Return all reasoning runs for a given chat, newest first."""

    db = await Database.instance()
    rows = await db.fetchall(
        """
        SELECT id, chat_id, mode, budgets_json, trace_json, citations_json, metrics_json, created_at
        FROM reasoning_runs
        WHERE chat_id = ?
        ORDER BY created_at DESC
        """,
        (chat_id,),
    )

    results = []
    for row in rows:
        results.append(
            {
                "id": row["id"],
                "chat_id": row["chat_id"],
                "mode": row["mode"],
                "budgets": json.loads(row["budgets_json"]) if row["budgets_json"] else {},
                "trace": json.loads(row["trace_json"]) if row["trace_json"] else [],
                "citations": json.loads(row["citations_json"]) if row["citations_json"] else [],
                "metrics": json.loads(row["metrics_json"]) if row["metrics_json"] else {},
                "created_at": row["created_at"],
            }
        )

    return results
