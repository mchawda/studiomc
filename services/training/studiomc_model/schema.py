# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Eval-aligned SFT case schema.

Training data and the eval harness share this shape so a case used to
score grounded QA / refuse / LRE tools is the same case used to train.

Accepted on disk (JSONL, one object per line):

* Native: ``id``, ``task``, ``question``, ``evidence``, ``expected_answer``,
  ``refuse``, ``tool_calls``.
* Eval-harness aliases: ``query``/``question``, ``contexts``/``evidence``,
  ``gold``/``expected``/``expected_answer``, ``should_refuse``/``refuse``,
  ``labels`` containing ``refuse`` or ``cite``.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, Literal

TaskType = Literal["grounded_qa", "refuse", "tool_plan", "tool_call"]

VALID_TASKS: frozenset[str] = frozenset(
    {"grounded_qa", "refuse", "tool_plan", "tool_call"}
)

# LRE tools from services/lre/tools.py plus planner's final inference step.
LRE_TOOLS: frozenset[str] = frozenset(
    {"search", "grep", "open", "summarize", "table_extract", "cite", "inference"}
)


@dataclass(frozen=True)
class EvidenceChunk:
    """One retrieved chunk, matching CLaRa / LRE citation fields."""

    doc_id: str
    filename: str
    chunk_index: int
    text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ExpectedToolCall:
    """One LRE / planner step: ``{"tool": name, "params": {...}}``."""

    tool: str
    params: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"tool": self.tool, "params": dict(self.params)}


@dataclass
class EvalCase:
    """One train/eval item. Keep this aligned with services/eval when it lands."""

    id: str
    task: TaskType
    question: str
    evidence: list[EvidenceChunk] = field(default_factory=list)
    expected_answer: str | None = None
    refuse: bool = False
    tool_calls: list[ExpectedToolCall] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "task": self.task,
            "question": self.question,
            "evidence": [e.to_dict() for e in self.evidence],
            "expected_answer": self.expected_answer,
            "refuse": self.refuse,
            "tool_calls": [t.to_dict() for t in self.tool_calls],
        }


def _as_evidence(raw: Any) -> EvidenceChunk:
    if not isinstance(raw, dict):
        raise ValueError("evidence item must be an object")
    text = raw.get("text") or raw.get("snippet") or raw.get("content") or ""
    if not str(text).strip():
        raise ValueError("evidence item missing text")
    return EvidenceChunk(
        doc_id=str(raw.get("doc_id") or raw.get("document_id") or raw.get("id") or "doc"),
        filename=str(raw.get("filename") or raw.get("source") or "document.txt"),
        chunk_index=int(raw.get("chunk_index") or raw.get("index") or 0),
        text=str(text).strip(),
    )


def _as_tool(raw: Any) -> ExpectedToolCall:
    if not isinstance(raw, dict):
        raise ValueError("tool_calls item must be an object")
    # Native LRE: {tool, params}. Qwen-style: {name, arguments}.
    tool = raw.get("tool") or raw.get("name") or ""
    params = raw.get("params") or raw.get("arguments") or {}
    if not tool:
        raise ValueError("tool_calls item missing tool/name")
    if not isinstance(params, dict):
        raise ValueError("tool params must be an object")
    return ExpectedToolCall(tool=str(tool), params=dict(params))


def _infer_task(obj: dict[str, Any], refuse: bool, tools: list[ExpectedToolCall]) -> TaskType:
    explicit = obj.get("task")
    if explicit in VALID_TASKS:
        return explicit  # type: ignore[return-value]
    labels = obj.get("labels") or []
    if refuse or "refuse" in labels:
        return "refuse"
    if tools:
        if obj.get("tool_style") == "plan" or explicit == "tool_plan":
            return "tool_plan"
        return "tool_call"
    return "grounded_qa"


def normalize_eval_record(obj: dict[str, Any], *, default_id: str = "case") -> EvalCase:
    """Map a native or eval-harness JSON object onto :class:`EvalCase`."""
    if not isinstance(obj, dict):
        raise ValueError("record must be a JSON object")

    question = (
        obj.get("question")
        or obj.get("query")
        or obj.get("prompt")
        or obj.get("input")
        or ""
    )
    question = str(question).strip()
    if not question:
        raise ValueError("record missing question/query")

    raw_evidence = (
        obj.get("evidence")
        or obj.get("contexts")
        or obj.get("sources")
        or obj.get("gold_sources")
        or []
    )
    if isinstance(raw_evidence, dict):
        raw_evidence = [raw_evidence]
    evidence: list[EvidenceChunk] = []
    for item in raw_evidence:
        if isinstance(item, dict) and not (
            item.get("text") or item.get("snippet") or item.get("content")
        ):
            # Eval gold_sources often have ids only; caller fills text from corpus.
            evidence.append(
                EvidenceChunk(
                    doc_id=str(item.get("document_id") or item.get("doc_id") or item.get("chunk_id") or "doc"),
                    filename=str(item.get("filename") or "document.txt"),
                    chunk_index=int(item.get("chunk_index") or 0),
                    text=str(item.get("chunk_id") or ""),
                )
            )
            continue
        evidence.append(_as_evidence(item))

    labels = obj.get("labels") or []
    kind = str(obj.get("kind") or "")
    refuse = bool(
        obj.get("refuse")
        or obj.get("should_refuse")
        or obj.get("must_refuse")
        or "refuse" in labels
        or kind in {"unanswerable", "partial_evidence"}
    )

    raw_tools = obj.get("tool_calls") or obj.get("tools") or obj.get("plan") or []
    if isinstance(raw_tools, dict):
        raw_tools = [raw_tools]
    tools = [_as_tool(item) for item in raw_tools]

    expected = (
        obj.get("expected_answer")
        or obj.get("gold")
        or obj.get("expected")
        or obj.get("answer")
    )
    if expected is not None:
        expected = str(expected).strip() or None

    task = _infer_task(obj, refuse, tools)
    case_id = str(obj.get("id") or obj.get("case_id") or default_id)

    return EvalCase(
        id=case_id,
        task=task,
        question=question,
        evidence=evidence,
        expected_answer=expected,
        refuse=refuse or task == "refuse",
        tool_calls=tools,
    )
