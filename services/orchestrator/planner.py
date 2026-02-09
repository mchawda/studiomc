"""Planner — decides which tools to call based on mode and query analysis.

For *fast* mode the planner is a no-op (go straight to inference).
For *cited* mode the plan is always: retrieve from CLaRa → generate cited answer.
For *investigate* mode the planner either uses the inference LLM to generate a
tool-use plan or falls back to heuristic keyword matching (MVP).
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field

import httpx

from common.config import INFERENCE_PORT

logger = logging.getLogger("orchestrator.planner")

# ── Plan data structures ────────────────────────────────────────────

INFERENCE_URL = f"http://127.0.0.1:{INFERENCE_PORT}/v1/chat/completions"

# Tool names that the planner can emit
TOOL_SEARCH = "search"
TOOL_OPEN = "open"
TOOL_GREP = "grep"
TOOL_SUMMARIZE = "summarize"
TOOL_TABLE_EXTRACT = "table_extract"
TOOL_CLARA_QUERY = "clara_query"
TOOL_CLARA_ANSWER = "clara_answer"
TOOL_INFERENCE = "inference"


@dataclass
class PlannedStep:
    """A single planned action the reasoning loop should execute."""

    tool: str  # one of the TOOL_* constants
    params: dict = field(default_factory=dict)


@dataclass
class Plan:
    """An ordered list of steps the reasoning loop will execute."""

    steps: list[PlannedStep] = field(default_factory=list)
    rationale: str = ""


# ── Keyword patterns for heuristic investigate planner ──────────────

_COMPARISON_RE = re.compile(
    r"\b(compar|differ|versus|vs\.?|contrast)\b", re.IGNORECASE
)
_DOC_REF_RE = re.compile(
    r"\b(document|file|page|section|chapter|table)\b", re.IGNORECASE
)
_TABLE_RE = re.compile(r"\b(table|spreadsheet|csv|column|row)\b", re.IGNORECASE)


# ── Public API ──────────────────────────────────────────────────────


async def make_plan(
    user_query: str,
    mode: str,
    *,
    collection_id: str | None = None,
    http: httpx.AsyncClient | None = None,
) -> Plan:
    """Return a :class:`Plan` for the given query and mode.

    Parameters
    ----------
    user_query : str
        The user's natural-language question.
    mode : str
        One of ``"fast"``, ``"cited"``, ``"investigate"``.
    collection_id : str | None
        Active document collection (needed for CLaRa calls).
    http : httpx.AsyncClient | None
        Reusable HTTP client (caller should manage lifetime).
    """

    if mode == "fast":
        return _plan_fast(user_query)

    if mode == "cited":
        return _plan_cited(user_query, collection_id)

    # investigate — try LLM planner first, fall back to heuristics
    if http is not None:
        try:
            return await _plan_investigate_llm(user_query, collection_id, http)
        except Exception:
            logger.warning("LLM planner failed, falling back to heuristics")

    return _plan_investigate_heuristic(user_query, collection_id)


# ── Private helpers ─────────────────────────────────────────────────


def _plan_fast(user_query: str) -> Plan:
    """Fast mode: single inference call, no retrieval."""
    return Plan(
        steps=[
            PlannedStep(
                tool=TOOL_INFERENCE,
                params={"query": user_query},
            )
        ],
        rationale="Fast mode — direct inference, no retrieval.",
    )


def _plan_cited(user_query: str, collection_id: str | None) -> Plan:
    """Cited mode: CLaRa retrieve → CLaRa cited-answer."""
    cid = collection_id or "default"
    return Plan(
        steps=[
            PlannedStep(
                tool=TOOL_CLARA_QUERY,
                params={"collection_id": cid, "query": user_query, "top_k": 8},
            ),
            PlannedStep(
                tool=TOOL_CLARA_ANSWER,
                params={"collection_id": cid, "query": user_query},
            ),
        ],
        rationale="Cited mode — retrieve chunks from CLaRa then generate cited answer.",
    )


def _plan_investigate_heuristic(
    user_query: str, collection_id: str | None
) -> Plan:
    """Heuristic investigate planner (MVP fallback)."""
    cid = collection_id or "default"
    steps: list[PlannedStep] = []

    # Always start with a search
    steps.append(
        PlannedStep(tool=TOOL_SEARCH, params={"query": user_query, "scope": cid})
    )

    # If the query references specific docs / pages → add open step
    if _DOC_REF_RE.search(user_query):
        steps.append(
            PlannedStep(
                tool=TOOL_OPEN, params={"doc_id": "__from_search__", "span": None}
            )
        )

    # If the query asks for a comparison → add grep + summarise
    if _COMPARISON_RE.search(user_query):
        steps.append(
            PlannedStep(tool=TOOL_GREP, params={"pattern": user_query[:60]})
        )
        steps.append(
            PlannedStep(
                tool=TOOL_SUMMARIZE,
                params={"doc_id": "__from_search__", "span": None},
            )
        )

    # If the query references tables → table extraction
    if _TABLE_RE.search(user_query):
        steps.append(
            PlannedStep(
                tool=TOOL_TABLE_EXTRACT,
                params={"doc_id": "__from_search__", "span": None},
            )
        )

    # Always end with a final inference to synthesize
    steps.append(
        PlannedStep(tool=TOOL_INFERENCE, params={"query": user_query})
    )

    return Plan(
        steps=steps,
        rationale="Investigate (heuristic) — keyword analysis determined tool sequence.",
    )


async def _plan_investigate_llm(
    user_query: str,
    collection_id: str | None,
    http: httpx.AsyncClient,
) -> Plan:
    """Ask the local LLM to generate a tool-use plan for investigate mode."""

    cid = collection_id or "default"
    system_prompt = (
        "You are a planning agent.  Given a user question, output a JSON array of "
        "tool steps.  Available tools: search, open, grep, summarize, table_extract, "
        "inference.  Each step is {\"tool\": \"<name>\", \"params\": {…}}.  "
        "Return ONLY valid JSON, no commentary."
    )

    resp = await http.post(
        INFERENCE_URL,
        json={
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_query},
            ],
            "temperature": 0.2,
            "max_tokens": 512,
        },
        timeout=8.0,
    )
    resp.raise_for_status()
    data = resp.json()
    content = data["choices"][0]["message"]["content"]

    # Parse JSON from the LLM response
    import json

    # Strip markdown code fences if present
    content = content.strip()
    if content.startswith("```"):
        content = "\n".join(content.split("\n")[1:])
    if content.endswith("```"):
        content = content.rsplit("```", 1)[0]

    raw_steps = json.loads(content.strip())

    steps: list[PlannedStep] = []
    for raw in raw_steps:
        tool = raw.get("tool", "")
        params = raw.get("params", {})
        # Inject collection_id where missing
        if tool in ("search",) and "scope" not in params:
            params["scope"] = cid
        steps.append(PlannedStep(tool=tool, params=params))

    # Guarantee a final inference step
    if not steps or steps[-1].tool != TOOL_INFERENCE:
        steps.append(PlannedStep(tool=TOOL_INFERENCE, params={"query": user_query}))

    return Plan(
        steps=steps,
        rationale="Investigate (LLM-planned) — model generated tool sequence.",
    )
