# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""SFT formatter + JSONL loader (torch-free).

Turns :class:`EvalCase` records into chat-format rows Unsloth / TRL can
train on. The same formatter is used for fixtures and for an eval-harness
export, so train and eval stay aligned.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterable

from training.studiomc_model.recipe import SYSTEM_PROMPT
from training.studiomc_model.schema import (
    EvalCase,
    EvidenceChunk,
    ExpectedToolCall,
    normalize_eval_record,
)

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
DEFAULT_SEED = FIXTURES_DIR / "sft_seed.jsonl"
_EVAL_DATA_DIR = Path(__file__).resolve().parents[2] / "eval" / "data"
DEFAULT_EVAL_GOLD = _EVAL_DATA_DIR / "gold.jsonl"
DEFAULT_EVAL_CORPUS = _EVAL_DATA_DIR / "corpus.json"

_EVAL_KIND_TASK = {
    "answerable": "grounded_qa",
    "multi_hop": "grounded_qa",
    "citation_trap": "grounded_qa",
    "unanswerable": "refuse",
    "partial_evidence": "refuse",
}

REFUSE_ANSWER = (
    "I cannot answer from the given sources. The retrieved evidence does "
    "not contain enough information."
)


def format_sources(case: EvalCase) -> str:
    """Numbered source blocks matching CLaRa's ``[Source N | doc= ...]`` prompt."""
    if not case.evidence:
        return "(no sources retrieved)"
    blocks: list[str] = []
    for i, chunk in enumerate(case.evidence, start=1):
        blocks.append(
            f"[Source {i} | doc={chunk.doc_id} chunk={chunk.chunk_index} | {chunk.filename}]\n"
            f"{chunk.text}"
        )
    return "\n\n".join(blocks)


def format_user_prompt(case: EvalCase) -> str:
    """User turn: sources + question, same shape as ``clara.retriever``."""
    if case.task in ("tool_plan", "tool_call") and not case.evidence:
        return (
            "Plan LRE tool steps for this question. "
            "Return only the tool JSON.\n\n"
            f"### Question\n{case.question}"
        )
    return (
        "Answer using ONLY the sources below. Cite as [Source N]. "
        "If the sources are insufficient, refuse.\n\n"
        f"### Sources\n{format_sources(case)}\n\n"
        f"### Question\n{case.question}\n\n"
        "### Answer"
    )


def format_tool_json(calls: Iterable[ExpectedToolCall], *, as_plan: bool) -> str:
    payload = [c.to_dict() for c in calls]
    if as_plan:
        return json.dumps(payload, ensure_ascii=False, indent=2)
    if len(payload) == 1:
        inner = json.dumps(payload[0], ensure_ascii=False)
        return f"<tool_call>\n{inner}\n</tool_call>"
    # Multi-call: one <tool_call> block per step (Qwen-style sequential).
    parts = [
        f"<tool_call>\n{json.dumps(item, ensure_ascii=False)}\n</tool_call>"
        for item in payload
    ]
    return "\n".join(parts)


def format_assistant(case: EvalCase) -> str:
    """Gold assistant turn for the given task."""
    if case.task == "refuse" or case.refuse:
        return case.expected_answer or REFUSE_ANSWER
    if case.task == "tool_plan":
        if not case.tool_calls:
            raise ValueError(f"{case.id}: tool_plan case has no tool_calls")
        return format_tool_json(case.tool_calls, as_plan=True)
    if case.task == "tool_call":
        if not case.tool_calls:
            raise ValueError(f"{case.id}: tool_call case has no tool_calls")
        return format_tool_json(case.tool_calls, as_plan=False)
    # grounded_qa
    if not case.expected_answer:
        raise ValueError(f"{case.id}: grounded_qa case missing expected_answer")
    return case.expected_answer


def case_to_messages(case: EvalCase) -> list[dict[str, str]]:
    """Chat messages for Unsloth ``apply_chat_template`` / TRL SFT."""
    return [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": format_user_prompt(case)},
        {"role": "assistant", "content": format_assistant(case)},
    ]


def case_to_sft_row(case: EvalCase) -> dict[str, Any]:
    """One JSONL row: messages plus the original eval case for alignment."""
    return {
        "id": case.id,
        "task": case.task,
        "messages": case_to_messages(case),
        "eval": case.to_dict(),
    }


def _looks_like_eval_gold(obj: dict[str, Any]) -> bool:
    return "kind" in obj or "gold_sources" in obj or "must_refuse" in obj


def _index_corpus(corpus_path: Path) -> dict[str, dict[str, Any]]:
    raw = json.loads(corpus_path.read_text(encoding="utf-8"))
    if not isinstance(raw, list):
        raise ValueError(f"{corpus_path}: corpus JSON must be a list")
    index: dict[str, dict[str, Any]] = {}
    for row in raw:
        if not isinstance(row, dict):
            continue
        cid = str(row.get("id") or row.get("chunk_id") or "")
        if cid:
            index[cid] = row
        key = (
            f"{row.get('document_id') or ''}::{row.get('chunk_index') or 0}"
        )
        index.setdefault(key, row)
    return index


def _resolve_eval_corpus(gold_path: Path, corpus_path: Path | None) -> Path | None:
    if corpus_path is not None and corpus_path.is_file():
        return corpus_path
    sibling = gold_path.parent / "corpus.json"
    if sibling.is_file():
        return sibling
    if DEFAULT_EVAL_CORPUS.is_file():
        return DEFAULT_EVAL_CORPUS
    return None


def _evidence_from_gold_source(
    src: dict[str, Any],
    corpus: dict[str, dict[str, Any]],
) -> EvidenceChunk | None:
    chunk_id = str(src.get("chunk_id") or src.get("id") or "")
    doc_key = f"{src.get('document_id') or ''}::{src.get('chunk_index') or 0}"
    row = corpus.get(chunk_id) or corpus.get(doc_key) or {}
    text = (
        src.get("text")
        or src.get("snippet")
        or row.get("text")
        or row.get("snippet")
        or ""
    )
    if not str(text).strip():
        return None
    return EvidenceChunk(
        doc_id=str(
            src.get("document_id")
            or row.get("document_id")
            or chunk_id
            or "doc"
        ),
        filename=str(src.get("filename") or row.get("filename") or "document.txt"),
        chunk_index=int(src.get("chunk_index") or row.get("chunk_index") or 0),
        text=str(text).strip(),
    )


def _templated_answer(evidence: list[EvidenceChunk]) -> str:
    """Cite every gold chunk. Keeps SFT aligned with eval gold_sources."""
    parts = [f"{chunk.text} [Source {i}]" for i, chunk in enumerate(evidence, 1)]
    return " ".join(parts)


def cases_from_eval_harness(
    gold_path: Path,
    corpus_path: Path | None = None,
) -> list[EvalCase]:
    """Turn eval ``gold.jsonl`` + ``corpus.json`` into SFT :class:`EvalCase`s."""
    corpus_file = _resolve_eval_corpus(gold_path, corpus_path)
    corpus = _index_corpus(corpus_file) if corpus_file is not None else {}

    cases: list[EvalCase] = []
    for i, line in enumerate(gold_path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        obj = json.loads(line)
        if not isinstance(obj, dict):
            continue
        question = str(obj.get("question") or obj.get("query") or "").strip()
        if not question:
            continue
        kind = str(obj.get("kind") or "")
        refuse = bool(obj.get("must_refuse") or kind in {"unanswerable", "partial_evidence"})
        evidence: list[EvidenceChunk] = []
        for src in obj.get("gold_sources") or obj.get("evidence") or []:
            if isinstance(src, dict):
                chunk = _evidence_from_gold_source(src, corpus)
                if chunk is not None:
                    evidence.append(chunk)
        task = _EVAL_KIND_TASK.get(kind, "refuse" if refuse else "grounded_qa")
        expected = obj.get("expected_answer") or obj.get("gold") or obj.get("answer")
        if expected:
            expected = str(expected).strip()
        elif refuse:
            expected = REFUSE_ANSWER
        elif evidence:
            expected = _templated_answer(evidence)
        else:
            expected = REFUSE_ANSWER
            refuse = True
            task = "refuse"
        cases.append(
            EvalCase(
                id=str(obj.get("id") or f"{gold_path.stem}-{i}"),
                task=task,  # type: ignore[arg-type]
                question=question,
                evidence=evidence,
                expected_answer=expected,
                refuse=refuse,
            )
        )
    return cases


def load_cases(path: Path, *, corpus_path: Path | None = None) -> list[EvalCase]:
    """Load JSONL (native, aliases, or eval-harness gold) into :class:`EvalCase`."""
    text = path.read_text(encoding="utf-8")
    first: dict[str, Any] | None = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        obj = json.loads(line)
        if isinstance(obj, dict):
            first = obj
        break
    if first is not None and _looks_like_eval_gold(first):
        return cases_from_eval_harness(path, corpus_path)

    cases: list[EvalCase] = []
    for i, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        obj = json.loads(line)
        cases.append(normalize_eval_record(obj, default_id=f"{path.stem}-{i}"))
    return cases


def load_seed_cases() -> list[EvalCase]:
    """Built-in fixtures shipped next to this module."""
    if not DEFAULT_SEED.is_file():
        raise FileNotFoundError(f"Missing seed fixtures: {DEFAULT_SEED}")
    return load_cases(DEFAULT_SEED)


def generate_sft_rows(
    cases: list[EvalCase] | None = None,
    *,
    extra_paths: list[Path] | None = None,
    include_eval_harness: bool = True,
) -> list[dict[str, Any]]:
    """Merge seed fixtures + eval gold (if present) + extra JSONL into SFT rows."""
    merged: list[EvalCase] = list(cases or load_seed_cases())
    if include_eval_harness and DEFAULT_EVAL_GOLD.is_file():
        merged.extend(cases_from_eval_harness(DEFAULT_EVAL_GOLD))
    for path in extra_paths or []:
        merged.extend(load_cases(path))
    seen: set[str] = set()
    rows: list[dict[str, Any]] = []
    for case in merged:
        if case.id in seen:
            continue
        seen.add(case.id)
        rows.append(case_to_sft_row(case))
    return rows


def write_sft_jsonl(rows: list[dict[str, Any]], dest: Path) -> Path:
    """Write chat-format SFT JSONL. Returns ``dest``."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(row, ensure_ascii=False) for row in rows]
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dest
