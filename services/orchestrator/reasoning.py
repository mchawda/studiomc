# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Recursive reasoning loop — plan → tool → observe → answer/sub-query.

Implements the RecursiveLM-style loop with strict budget enforcement:
  - Max tool calls: 6
  - Max recursion depth: 2
  - Retrieved-text cap: 8 000 tokens (approx)
  - Wall-clock limits: 20 s (investigate), 8 s (fast / cited)
"""

from __future__ import annotations

import json
import logging
import time
import uuid
from dataclasses import dataclass, field

import httpx

from common.config import CLARA_PORT, INFERENCE_PORT, LRE_PORT
from common.database import Database
from common.schemas import (
    Citation,
    ReasoningMode,
    ReasoningRequest,
    ReasoningResponse,
    TraceStep,
)

from orchestrator.planner import (
    TOOL_CLARA_ANSWER,
    TOOL_CLARA_QUERY,
    TOOL_GREP,
    TOOL_INFERENCE,
    TOOL_OPEN,
    TOOL_SEARCH,
    TOOL_SUMMARIZE,
    TOOL_TABLE_EXTRACT,
    Plan,
    PlannedStep,
    make_plan,
)

logger = logging.getLogger("orchestrator.reasoning")

# ── Service URLs ────────────────────────────────────────────────────

INFERENCE_URL = f"http://127.0.0.1:{INFERENCE_PORT}/v1/chat/completions"
CLARA_QUERY_URL = f"http://127.0.0.1:{CLARA_PORT}/clara/query"
CLARA_ANSWER_URL = f"http://127.0.0.1:{CLARA_PORT}/clara/answer"
LRE_EXECUTE_URL = f"http://127.0.0.1:{LRE_PORT}/lre/execute"

# ── Budget defaults ─────────────────────────────────────────────────

DEFAULT_BUDGETS: dict[str, int | float] = {
    "max_tool_calls": 6,
    "max_depth": 2,
    "max_retrieved_tokens": 8_000,
    "wall_clock_fast": 8.0,
    "wall_clock_cited": 8.0,
    "wall_clock_investigate": 20.0,
}

# Rough chars-per-token ratio for budget accounting
_CHARS_PER_TOKEN = 4


@dataclass
class _RunState:
    """Mutable state tracked across a single reasoning run."""

    run_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    tool_calls: int = 0
    depth: int = 0
    retrieved_tokens: int = 0
    trace: list[TraceStep] = field(default_factory=list)
    citations: list[Citation] = field(default_factory=list)
    context_chunks: list[str] = field(default_factory=list)
    stopped_reason: str | None = None
    start_time: float = field(default_factory=time.monotonic)

    # Resolved budgets
    max_tool_calls: int = 6
    max_depth: int = 2
    max_retrieved_tokens: int = 8_000
    wall_clock_limit: float = 20.0


# ── Public entry point ──────────────────────────────────────────────


async def run_reasoning(request: ReasoningRequest) -> ReasoningResponse:
    """Execute a full reasoning run and persist results to the database."""

    mode = request.mode.value
    budgets = {**DEFAULT_BUDGETS, **(request.budgets or {})}

    wall_key = f"wall_clock_{mode}"
    wall_limit = float(budgets.get(wall_key, DEFAULT_BUDGETS.get(wall_key, 20.0)))

    state = _RunState(
        max_tool_calls=int(budgets.get("max_tool_calls", 6)),
        max_depth=int(budgets.get("max_depth", 2)),
        max_retrieved_tokens=int(budgets.get("max_retrieved_tokens", 8_000)),
        wall_clock_limit=wall_limit,
    )

    async with httpx.AsyncClient() as http:
        plan = await make_plan(request.user_query, mode, http=http)
        logger.info(
            "Plan for chat=%s mode=%s steps=%d rationale=%s",
            request.chat_id,
            mode,
            len(plan.steps),
            plan.rationale,
        )

        answer = await _execute_plan(
            plan=plan,
            query=request.user_query,
            mode=mode,
            state=state,
            http=http,
        )

    total_ms = int((time.monotonic() - state.start_time) * 1000)
    metrics = {
        "total_ms": total_ms,
        "tool_calls": state.tool_calls,
        "retrieved_tokens": state.retrieved_tokens,
        "depth": state.depth,
    }

    groundedness = _compute_groundedness(answer, state.citations)

    response = ReasoningResponse(
        answer=answer,
        citations=state.citations,
        groundedness=groundedness,
        trace=state.trace,
        metrics=metrics,
        stopped_reason=state.stopped_reason,
    )

    # Persist to database (fire-and-forget style, errors logged)
    try:
        await _persist_run(request, state, response)
    except Exception:
        logger.exception("Failed to persist reasoning run %s", state.run_id)

    return response


# ── Core execution ──────────────────────────────────────────────────


async def _execute_plan(
    *,
    plan: Plan,
    query: str,
    mode: str,
    state: _RunState,
    http: httpx.AsyncClient,
) -> str:
    """Walk through the plan steps, enforcing budgets at every iteration."""

    answer = ""

    for step in plan.steps:
        # ── Budget checks ───────────────────────────────────────
        if _budget_exceeded(state):
            break

        # ── Execute tool ────────────────────────────────────────
        t0 = time.monotonic()
        try:
            result = await _dispatch_tool(step, query, state, http)
        except Exception as exc:
            logger.warning("Tool %s failed: %s", step.tool, exc)
            result = f"[error] {exc}"

        duration_ms = int((time.monotonic() - t0) * 1000)
        state.tool_calls += 1

        # Record trace
        state.trace.append(
            TraceStep(
                tool=step.tool,
                input=step.params,
                output=result[:2000],  # truncate for storage
                duration_ms=duration_ms,
            )
        )

        # ── Observe ─────────────────────────────────────────────
        _observe(result, step.tool, state)

        # If the step was a final inference, treat result as the answer
        if step.tool == TOOL_INFERENCE:
            answer = result
        elif step.tool == TOOL_CLARA_ANSWER:
            answer = result

    # If we never reached an inference step (budget cut short), synthesize
    if not answer:
        if state.context_chunks:
            answer = (
                "Based on the retrieved information:\n\n"
                + "\n---\n".join(state.context_chunks[:3])
            )
        else:
            answer = "I was unable to complete the analysis within the given budget."

    return answer


def _budget_exceeded(state: _RunState) -> bool:
    """Return True and set stopped_reason if any budget is blown."""

    elapsed = time.monotonic() - state.start_time
    if elapsed >= state.wall_clock_limit:
        state.stopped_reason = "wall_clock_exceeded"
        logger.info("Wall-clock budget exceeded (%.1fs)", elapsed)
        return True

    if state.tool_calls >= state.max_tool_calls:
        state.stopped_reason = "budget_exceeded"
        logger.info("Tool-call budget exceeded (%d)", state.tool_calls)
        return True

    if state.retrieved_tokens >= state.max_retrieved_tokens:
        state.stopped_reason = "budget_exceeded"
        logger.info("Retrieved-token budget exceeded (%d)", state.retrieved_tokens)
        return True

    return False


def _observe(result: str, tool: str, state: _RunState) -> None:
    """Process a tool result — update context and token accounting."""

    if tool in (
        TOOL_CLARA_QUERY,
        TOOL_SEARCH,
        TOOL_OPEN,
        TOOL_GREP,
        TOOL_SUMMARIZE,
        TOOL_TABLE_EXTRACT,
    ):
        # Count towards retrieved token budget
        approx_tokens = len(result) // _CHARS_PER_TOKEN
        state.retrieved_tokens += approx_tokens
        state.context_chunks.append(result)


# ── Tool dispatch ───────────────────────────────────────────────────


async def _dispatch_tool(
    step: PlannedStep,
    query: str,
    state: _RunState,
    http: httpx.AsyncClient,
) -> str:
    """Call the appropriate service for the given planned step."""

    tool = step.tool
    params = step.params

    if tool == TOOL_INFERENCE:
        return await _call_inference(query, state, http)

    if tool == TOOL_CLARA_QUERY:
        return await _call_clara_query(params, http, state)

    if tool == TOOL_CLARA_ANSWER:
        return await _call_clara_answer(params, query, http, state)

    if tool in (TOOL_SEARCH, TOOL_OPEN, TOOL_GREP, TOOL_SUMMARIZE, TOOL_TABLE_EXTRACT):
        return await _call_lre(tool, params, http)

    return f"[unknown tool: {tool}]"


# ── Inference ───────────────────────────────────────────────────────


async def _call_inference(
    query: str,
    state: _RunState,
    http: httpx.AsyncClient,
) -> str:
    """Call the local inference service with accumulated context."""

    messages: list[dict[str, str]] = []

    # If we have retrieved context, inject it as a system message
    if state.context_chunks:
        context_text = "\n---\n".join(state.context_chunks)
        # Trim to budget
        max_chars = state.max_retrieved_tokens * _CHARS_PER_TOKEN
        if len(context_text) > max_chars:
            context_text = context_text[:max_chars] + "\n[…truncated]"
        messages.append(
            {
                "role": "system",
                "content": (
                    "Use the following retrieved context to answer the user's question. "
                    "Cite sources where possible.\n\n" + context_text
                ),
            }
        )

    messages.append({"role": "user", "content": query})

    remaining = state.wall_clock_limit - (time.monotonic() - state.start_time)
    timeout = max(remaining, 2.0)

    resp = await http.post(
        INFERENCE_URL,
        json={"messages": messages, "temperature": 0.7, "max_tokens": 1024},
        timeout=timeout,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["choices"][0]["message"]["content"]


# ── CLaRa ───────────────────────────────────────────────────────────


async def _call_clara_query(
    params: dict,
    http: httpx.AsyncClient,
    state: _RunState,
) -> str:
    """POST /clara/query — semantic retrieval of document chunks."""

    body = {
        "collection_id": params.get("collection_id", "default"),
        "query": params.get("query", ""),
        "top_k": params.get("top_k", 8),
        "include_snippets": True,
    }
    remaining = state.wall_clock_limit - (time.monotonic() - state.start_time)
    resp = await http.post(CLARA_QUERY_URL, json=body, timeout=max(remaining, 2.0))
    resp.raise_for_status()
    data = resp.json()

    # Extract citations
    chunks = data.get("chunks", [])
    scores = data.get("scores", [])
    snippets = data.get("snippets", [])
    for i, chunk in enumerate(chunks):
        score = scores[i] if i < len(scores) else 0.0
        snippet = snippets[i] if i < len(snippets) else chunk.get("text", "")[:200]
        state.citations.append(
            Citation(
                document_id=chunk.get("document_id", ""),
                filename=chunk.get("metadata_json", "") or "",
                chunk_index=chunk.get("chunk_index", 0),
                snippet=snippet,
                relevance_score=score,
            )
        )

    # Return combined text for the observe step
    combined = "\n---\n".join(
        snippets if snippets else [c.get("text", "") for c in chunks]
    )
    return combined


async def _call_clara_answer(
    params: dict,
    query: str,
    http: httpx.AsyncClient,
    state: _RunState,
) -> str:
    """POST /clara/answer — cited answer generation."""

    body = {
        "collection_id": params.get("collection_id", "default"),
        "query": query,
        "mode": "cited",
        "top_k": params.get("top_k", 8),
    }
    remaining = state.wall_clock_limit - (time.monotonic() - state.start_time)
    resp = await http.post(CLARA_ANSWER_URL, json=body, timeout=max(remaining, 2.0))
    resp.raise_for_status()
    data = resp.json()

    # Merge citations from CLaRa answer if present
    for cit in data.get("citations", []):
        state.citations.append(Citation(**cit))

    return data.get("answer", "")


# ── LRE (Local Research Environment) ───────────────────────────────


async def _call_lre(
    tool: str,
    params: dict,
    http: httpx.AsyncClient,
) -> str:
    """POST /lre/execute — run an LRE tool (search, open, grep, summarize, table_extract)."""

    body = {"tool": tool, "params": params}
    resp = await http.post(LRE_EXECUTE_URL, json=body, timeout=15.0)
    resp.raise_for_status()
    data = resp.json()
    return data.get("result", json.dumps(data))


# ── Sub-query recursion ─────────────────────────────────────────────


async def run_sub_query(
    sub_query: str,
    state: _RunState,
    http: httpx.AsyncClient,
) -> str:
    """Execute a recursive sub-query within the same run, sharing state.

    This increments depth and reuses the same budget counters so the
    overall run stays within limits.
    """

    if state.depth >= state.max_depth:
        state.stopped_reason = "budget_exceeded"
        return "[max recursion depth reached]"

    state.depth += 1
    sub_plan = await make_plan(sub_query, "investigate", http=http)

    answer = await _execute_plan(
        plan=sub_plan,
        query=sub_query,
        mode="investigate",
        state=state,
        http=http,
    )

    return answer


# ── Groundedness calculation ────────────────────────────────────────


def _compute_groundedness(
    answer: str,
    citations: list[Citation],
    relevance_threshold: float = 0.5,
) -> float:
    """Compute groundedness as the fraction of answer claims supported by citations.

    A "claim" is approximated as a sentence in the answer.
    A claim is "supported" if there exists at least one citation whose
    ``relevance_score`` exceeds *relevance_threshold*.

    Returns a float between 0.0 and 1.0.  If there are no claims or no
    citations the result is 0.0.
    """

    if not answer or not citations:
        return 0.0

    import re

    # Split answer into sentences (claims)
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", answer) if s.strip()]
    total_claims = len(sentences)
    if total_claims == 0:
        return 0.0

    # Count citations that meet the relevance threshold
    strong_citations = [c for c in citations if c.relevance_score > relevance_threshold]
    if not strong_citations:
        return 0.0

    # For each sentence, check whether any strong citation's snippet shares
    # significant keyword overlap (lightweight heuristic — no NLI model).
    supported = 0
    for sentence in sentences:
        sentence_words = set(re.findall(r"\w{3,}", sentence.lower()))
        if not sentence_words:
            continue
        for cit in strong_citations:
            cit_words = set(re.findall(r"\w{3,}", cit.snippet.lower()))
            overlap = sentence_words & cit_words
            # If ≥30 % of sentence words appear in the citation → supported
            if len(overlap) >= max(1, len(sentence_words) * 0.3):
                supported += 1
                break

    return round(supported / total_claims, 4)


# ── Database persistence ────────────────────────────────────────────


async def _persist_run(
    request: ReasoningRequest,
    state: _RunState,
    response: ReasoningResponse,
) -> None:
    """Save the completed reasoning run to the reasoning_runs table."""

    db = await Database.instance()
    await db.execute(
        """
        INSERT INTO reasoning_runs (id, chat_id, mode, budgets_json, trace_json, citations_json, metrics_json)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            state.run_id,
            request.chat_id,
            request.mode.value,
            json.dumps(request.budgets or {}),
            json.dumps([s.model_dump() for s in response.trace]),
            json.dumps([c.model_dump() for c in response.citations]),
            json.dumps(response.metrics),
        ),
    )
    await db.commit()
    logger.info("Persisted reasoning run %s for chat %s", state.run_id, request.chat_id)
