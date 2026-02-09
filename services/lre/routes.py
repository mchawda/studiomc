"""API routes for the LRE service.

All routes are prefixed with /lre and are internal-only
(called by the Orchestrator, never exposed to the user directly).
"""

from __future__ import annotations

import time
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from common.schemas import (
    Citation,
    LREGrepRequest,
    LREOpenRequest,
    LRESearchRequest,
    LRESummarizeRequest,
    LRETableExtractRequest,
    TraceStep,
)

from lre.sandbox import (
    BudgetExceeded,
    SecurityViolation,
    SessionBudget,
    validate_tool_name,
)
from lre.tools import TOOL_REGISTRY

router = APIRouter(prefix="/lre", tags=["LRE"])


# ── Request / Response helpers ──────────────────────────────────────────


class LREExecuteRequest(BaseModel):
    """Dispatcher: execute any allowlisted tool by name."""

    tool: str
    params: dict[str, Any] = Field(default_factory=dict)
    session_id: str | None = None


class LREToolResponse(BaseModel):
    """Uniform wrapper for all tool results."""

    ok: bool = True
    result: dict[str, Any] = Field(default_factory=dict)
    budget: dict[str, Any] = Field(default_factory=dict)
    stopped_reason: str | None = None


# ── Session budget store (in-memory, keyed by session_id) ──────────────

_sessions: dict[str, SessionBudget] = {}


def _get_budget(session_id: str | None) -> SessionBudget:
    """Get or create a SessionBudget for the given session."""
    key = session_id or "__default__"
    if key not in _sessions:
        _sessions[key] = SessionBudget()
    return _sessions[key]


def _cleanup_expired_sessions() -> None:
    """Remove expired sessions to avoid unbounded memory growth."""
    expired = [k for k, v in _sessions.items() if v.is_expired and v.elapsed_s > 120]
    for k in expired:
        del _sessions[k]


async def _run_tool(
    tool_name: str,
    params: dict[str, Any],
    budget: SessionBudget,
) -> LREToolResponse:
    """Validate, budget-check, execute a tool, and cap output tokens."""
    try:
        validate_tool_name(tool_name)
    except SecurityViolation as exc:
        raise HTTPException(status_code=403, detail=exc.reason)

    try:
        budget.consume_tool_call()
    except BudgetExceeded as exc:
        return LREToolResponse(
            ok=False,
            stopped_reason=f"I stopped because: {exc.reason}",
            budget=budget.status_dict(),
        )

    fn = TOOL_REGISTRY.get(tool_name)
    if fn is None:
        raise HTTPException(status_code=404, detail=f"Unknown tool: {tool_name}")

    try:
        result = await fn(**params)
    except SecurityViolation as exc:
        raise HTTPException(status_code=403, detail=exc.reason)
    except TypeError as exc:
        raise HTTPException(
            status_code=422, detail=f"Invalid parameters for {tool_name}: {exc}"
        )

    # Cap any text fields in the result against the token budget
    for key in ("text", "summary"):
        if key in result and isinstance(result[key], str):
            result[key] = budget.consume_tokens(result[key])

    # Also cap results list text
    if "results" in result and isinstance(result["results"], list):
        capped_results = []
        for item in result["results"]:
            if isinstance(item, dict) and "text" in item:
                item["text"] = budget.consume_tokens(item["text"])
            capped_results.append(item)
        result["results"] = capped_results

    # Cap match texts from grep
    if "matches" in result and isinstance(result["matches"], list):
        capped_matches = []
        for item in result["matches"]:
            if isinstance(item, dict) and "text" in item:
                item["text"] = budget.consume_tokens(item["text"])
            capped_matches.append(item)
        result["matches"] = capped_matches

    return LREToolResponse(
        ok=True,
        result=result,
        budget=budget.status_dict(),
    )


# ── Health ──────────────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    _cleanup_expired_sessions()
    return {"status": "ok", "service": "lre"}


# ── Individual tool endpoints ───────────────────────────────────────────


@router.post("/search", response_model=LREToolResponse)
async def lre_search(req: LRESearchRequest) -> LREToolResponse:
    budget = _get_budget(None)
    return await _run_tool("search", {"query": req.query, "scope": req.scope}, budget)


@router.post("/grep", response_model=LREToolResponse)
async def lre_grep(req: LREGrepRequest) -> LREToolResponse:
    budget = _get_budget(None)
    return await _run_tool("grep", {"pattern": req.pattern, "files": req.files}, budget)


@router.post("/open", response_model=LREToolResponse)
async def lre_open(req: LREOpenRequest) -> LREToolResponse:
    budget = _get_budget(None)
    return await _run_tool("open", {"doc_id": req.doc_id, "span": req.span}, budget)


@router.post("/summarize", response_model=LREToolResponse)
async def lre_summarize(req: LRESummarizeRequest) -> LREToolResponse:
    budget = _get_budget(None)
    return await _run_tool(
        "summarize", {"doc_id": req.doc_id, "span": req.span}, budget
    )


@router.post("/table_extract", response_model=LREToolResponse)
async def lre_table_extract(req: LRETableExtractRequest) -> LREToolResponse:
    budget = _get_budget(None)
    return await _run_tool(
        "table_extract", {"doc_id": req.doc_id, "span": req.span}, budget
    )


@router.post("/cite", response_model=LREToolResponse)
async def lre_cite(req: Request) -> LREToolResponse:
    """Create a citation. Accepts {doc_id, chunk_index, snippet?, relevance_score?}."""
    body = await req.json()
    budget = _get_budget(None)
    params = {
        "doc_id": body.get("doc_id", ""),
        "chunk_index": body.get("chunk_index", 0),
        "snippet": body.get("snippet", ""),
        "relevance_score": body.get("relevance_score", 1.0),
    }
    return await _run_tool("cite", params, budget)


# ── Generic dispatcher ──────────────────────────────────────────────────


@router.post("/execute", response_model=LREToolResponse)
async def lre_execute(req: LREExecuteRequest) -> LREToolResponse:
    """Execute any allowlisted tool by name — used by the Orchestrator's
    reasoning loop to dynamically dispatch tool calls."""
    budget = _get_budget(req.session_id)
    return await _run_tool(req.tool, req.params, budget)
