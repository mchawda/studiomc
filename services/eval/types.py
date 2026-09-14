# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Eval types aligned with CLaRa / orchestrator citation shapes.

Production citations (:class:`common.schemas.Citation`) carry
``document_id``, ``filename``, ``chunk_index``, ``snippet``, and
``relevance_score``. Chunks (:class:`common.schemas.DocChunk`) add a
stable ``id``. Gold fixtures accept either identity:

* ``chunk_id`` (doc_chunks.id)
* ``(document_id, chunk_index)``
* ``(filename, chunk_index)`` as a file+span fallback
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

ItemKind = Literal[
    "answerable",
    "unanswerable",
    "partial_evidence",
    "multi_hop",
    "citation_trap",
]


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _as_float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class SourceRef:
    """A gold or predicted source pointer.

    Extra eval-only fields (``chunk_id``, ``span``) sit alongside the
    production Citation identity so recorded CLaRa / orchestrator JSON
    can be scored without rewriting it.
    """

    chunk_id: str = ""
    document_id: str = ""
    filename: str = ""
    chunk_index: int = 0
    snippet: str = ""
    relevance_score: float = 0.0
    span: tuple[int, int] | None = None

    def identity_keys(self) -> set[tuple[Any, ...]]:
        """Comparable keys used for precision / recall matching."""
        keys: set[tuple[Any, ...]] = set()
        if self.chunk_id:
            keys.add(("chunk_id", self.chunk_id))
        if self.document_id:
            keys.add(("doc_idx", self.document_id, self.chunk_index))
        if self.filename:
            keys.add(("file_idx", self.filename.lower(), self.chunk_index))
        return keys

    def matches(self, other: SourceRef) -> bool:
        a = self.identity_keys()
        b = other.identity_keys()
        return bool(a and b and (a & b))

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> SourceRef:
        span_raw = raw.get("span")
        span: tuple[int, int] | None = None
        if isinstance(span_raw, dict):
            start = span_raw.get("start_char", span_raw.get("start"))
            end = span_raw.get("end_char", span_raw.get("end"))
            if start is not None and end is not None:
                span = (_as_int(start), _as_int(end))
        elif isinstance(span_raw, (list, tuple)) and len(span_raw) == 2:
            span = (_as_int(span_raw[0]), _as_int(span_raw[1]))
        return cls(
            chunk_id=str(raw.get("chunk_id") or raw.get("id") or ""),
            document_id=str(raw.get("document_id") or ""),
            filename=str(raw.get("filename") or ""),
            chunk_index=_as_int(raw.get("chunk_index"), 0),
            snippet=str(raw.get("snippet") or raw.get("text") or ""),
            relevance_score=_as_float(raw.get("relevance_score"), 0.0),
            span=span,
        )

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "chunk_id": self.chunk_id,
            "document_id": self.document_id,
            "filename": self.filename,
            "chunk_index": self.chunk_index,
            "snippet": self.snippet,
            "relevance_score": self.relevance_score,
        }
        if self.span is not None:
            out["span"] = {"start_char": self.span[0], "end_char": self.span[1]}
        return out


@dataclass(frozen=True)
class CorpusChunk:
    """A fixture chunk, shaped like ``DocChunk`` plus filename."""

    id: str
    document_id: str
    filename: str
    chunk_index: int
    text: str
    token_count: int | None = None

    def as_source(self) -> SourceRef:
        return SourceRef(
            chunk_id=self.id,
            document_id=self.document_id,
            filename=self.filename,
            chunk_index=self.chunk_index,
            snippet=self.text[:300],
        )

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> CorpusChunk:
        return cls(
            id=str(raw.get("id") or raw.get("chunk_id") or ""),
            document_id=str(raw.get("document_id") or ""),
            filename=str(raw.get("filename") or ""),
            chunk_index=_as_int(raw.get("chunk_index"), 0),
            text=str(raw.get("text") or ""),
            token_count=int(raw["token_count"]) if raw.get("token_count") is not None else None,
        )


@dataclass
class GoldItem:
    """One grounded-answering eval example."""

    id: str
    kind: ItemKind
    question: str
    gold_sources: list[SourceRef] = field(default_factory=list)
    must_refuse: bool = False
    notes: str = ""

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> GoldItem:
        kind = str(raw.get("kind") or "answerable")
        if kind not in {
            "answerable",
            "unanswerable",
            "partial_evidence",
            "multi_hop",
            "citation_trap",
        }:
            raise ValueError(f"unknown gold item kind: {kind!r}")
        sources = [SourceRef.from_dict(s) for s in raw.get("gold_sources") or []]
        return cls(
            id=str(raw["id"]),
            kind=kind,  # type: ignore[arg-type]
            question=str(raw.get("question") or ""),
            gold_sources=sources,
            must_refuse=bool(raw.get("must_refuse", False)),
            notes=str(raw.get("notes") or ""),
        )


@dataclass
class Prediction:
    """Recorded or live model output for one gold item.

    ``retrieved_chunk_ids`` is the context the model actually saw (CLaRa
    top-k). Structured ``citations`` match :class:`Citation`. If they are
    omitted, ``[Source N]`` markers in ``answer`` are resolved against
    ``retrieved`` order, same as ``clara.retriever._extract_citations``.
    """

    id: str
    answer: str
    citations: list[SourceRef] = field(default_factory=list)
    retrieved_chunk_ids: list[str] = field(default_factory=list)
    retrieved: list[CorpusChunk] = field(default_factory=list)
    refused: bool | None = None
    # Model that produced ``answer`` (e.g. "studiomc-4b@Q4_K_M"). Recorded
    # JSONL may carry this per row; the runner lifts it into RunMetadata.
    model_version: str = ""

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> Prediction:
        citations = [SourceRef.from_dict(c) for c in raw.get("citations") or []]
        retrieved = [CorpusChunk.from_dict(c) for c in raw.get("retrieved") or []]
        ids = [str(x) for x in raw.get("retrieved_chunk_ids") or []]
        if not ids and retrieved:
            ids = [c.id for c in retrieved]
        refused = raw.get("refused")
        return cls(
            id=str(raw["id"]),
            answer=str(raw.get("answer") or ""),
            citations=citations,
            retrieved_chunk_ids=ids,
            retrieved=retrieved,
            refused=None if refused is None else bool(refused),
            model_version=str(raw.get("model_version") or raw.get("model") or ""),
        )


@dataclass(frozen=True)
class RunMetadata:
    """Provenance for one eval run (AI output standard).

    Every scored suite carries the model version that produced the
    answers, a UTC timestamp, and a reference to the exact inputs
    (paths plus sha256) so a score can be reproduced and audited.
    """

    model_version: str
    timestamp: str
    input_reference: dict[str, Any]
    harness_version: str
    mode: str
    top_k: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "model_version": self.model_version,
            "timestamp": self.timestamp,
            "input_reference": dict(self.input_reference),
            "harness_version": self.harness_version,
            "mode": self.mode,
            "top_k": self.top_k,
        }


@dataclass
class ItemScore:
    id: str
    kind: str
    must_refuse: bool
    refused: bool
    refusal_correct: bool
    grounding: float
    citation_precision: float
    citation_recall: float
    citation_f1: float
    citation_hallucination_rate: float
    n_gold_sources: int
    n_pred_citations: int
    n_retrieved: int
    retrieval_hit_at_k: float | None
    retrieval_recall_at_k: float | None
    notes: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "must_refuse": self.must_refuse,
            "refused": self.refused,
            "refusal_correct": self.refusal_correct,
            "grounding": self.grounding,
            "citation_precision": self.citation_precision,
            "citation_recall": self.citation_recall,
            "citation_f1": self.citation_f1,
            "citation_hallucination_rate": self.citation_hallucination_rate,
            "n_gold_sources": self.n_gold_sources,
            "n_pred_citations": self.n_pred_citations,
            "n_retrieved": self.n_retrieved,
            "retrieval_hit_at_k": self.retrieval_hit_at_k,
            "retrieval_recall_at_k": self.retrieval_recall_at_k,
            "notes": self.notes,
        }


@dataclass
class SuiteScore:
    items: list[ItemScore]
    n: int
    grounding: float
    citation_precision: float
    citation_recall: float
    citation_f1: float
    citation_hallucination_rate: float
    refusal_accuracy: float
    refusal_accuracy_unanswerable: float
    retrieval_hit_at_k: float | None
    retrieval_recall_at_k: float | None
    by_kind: dict[str, float] = field(default_factory=dict)
    metadata: RunMetadata | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "metadata": self.metadata.to_dict() if self.metadata else None,
            "n": self.n,
            "grounding": self.grounding,
            "citation_precision": self.citation_precision,
            "citation_recall": self.citation_recall,
            "citation_f1": self.citation_f1,
            "citation_hallucination_rate": self.citation_hallucination_rate,
            "refusal_accuracy": self.refusal_accuracy,
            "refusal_accuracy_unanswerable": self.refusal_accuracy_unanswerable,
            "retrieval_hit_at_k": self.retrieval_hit_at_k,
            "retrieval_recall_at_k": self.retrieval_recall_at_k,
            "by_kind": self.by_kind,
            "items": [i.to_dict() for i in self.items],
        }
