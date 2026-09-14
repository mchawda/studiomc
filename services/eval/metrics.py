# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Pure-Python grounded-answering metrics. No torch, no CLaRa import.

Grounding matches the CLaRa / orchestrator overlap heuristic: a claim
(sentence) is supported when >= 30% of its 3+ character tokens appear in
the retrieved context. Citation identity matches ``chunk_id`` or
``(document_id|filename, chunk_index)``.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Sequence

from eval.types import CorpusChunk, SourceRef

# Orchestrator uses words of length >= 3; keep that here so scores stay
# comparable to production groundedness.
_WORD_RE = re.compile(r"\w{3,}")
_SENT_RE = re.compile(r"(?<=[.!?])\s+")
_SOURCE_RE = re.compile(r"\[Source\s+(\d+)\]", re.IGNORECASE)

# Phrases CLaRa, the orchestrator, and this harness emit on refusal.
_REFUSAL_RE = re.compile(
    r"(?i)\b("
    r"i don't know|i do not know|"
    r"insufficient (?:evidence|information|context)|"
    r"cannot (?:be )?(?:answered|determined|found|verified)|"
    r"could not find|"
    r"no (?:relevant )?(?:sources|evidence|information)|"
    r"not (?:enough|sufficient) (?:information|evidence)|"
    r"unable to (?:answer|verify|determine)|"
    r"the (?:provided )?sources? (?:do not|don't|cannot)|"
    r"i could not find any relevant sources"
    r")\b"
)

GROUNDING_OVERLAP = 0.30


def tokenize(text: str) -> set[str]:
    """Return the 3+ character word set used for overlap checks."""
    return set(_WORD_RE.findall(text.lower()))


def _strip_source_markers(text: str) -> str:
    return _SOURCE_RE.sub("", text)


def split_claims(answer: str) -> list[str]:
    """Split an answer into claim-like sentences.

    ``[Source N]`` markers are removed first so a trailing cite is not
    scored as an unsupported claim.
    """
    cleaned = _strip_source_markers(answer)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    parts = [s.strip(" ,;") for s in _SENT_RE.split(cleaned) if s.strip(" ,;")]
    if parts:
        return parts
    return [cleaned] if cleaned else []


def is_refusal_text(answer: str) -> bool:
    """True when the answer is an I-don't-know / insufficient-evidence refusal."""
    if not answer or not answer.strip():
        return True
    return _REFUSAL_RE.search(answer) is not None


def parse_source_markers(answer: str) -> list[int]:
    """Return 0-based retrieved-chunk indexes cited as ``[Source N]``."""
    seen: set[int] = set()
    indexes: list[int] = []
    for match in _SOURCE_RE.finditer(answer):
        idx = int(match.group(1)) - 1
        if idx < 0 or idx in seen:
            continue
        seen.add(idx)
        indexes.append(idx)
    return indexes


def citations_from_source_markers(
    answer: str,
    retrieved: Sequence[CorpusChunk],
) -> list[SourceRef]:
    """Resolve ``[Source N]`` markers the same way CLaRa does."""
    citations: list[SourceRef] = []
    for idx in parse_source_markers(answer):
        if idx >= len(retrieved):
            continue
        citations.append(retrieved[idx].as_source())
    return citations


def resolve_citations(
    answer: str,
    explicit: Sequence[SourceRef],
    retrieved: Sequence[CorpusChunk],
) -> list[SourceRef]:
    """Prefer structured citations; fall back to ``[Source N]`` parsing."""
    if explicit:
        return list(explicit)
    if retrieved:
        return citations_from_source_markers(answer, retrieved)
    return []


def precision_recall(
    predicted: Sequence[SourceRef],
    gold: Sequence[SourceRef],
) -> tuple[float, float, float]:
    """Citation precision, recall, and F1 against gold source identities.

    Empty gold and empty pred scores 1 / 1 / 1 (correct silence).
    Empty gold and nonempty pred scores 0 / 1 / 0 (spurious cites).
    """
    if not gold and not predicted:
        return 1.0, 1.0, 1.0
    if not gold:
        return 0.0, 1.0, 0.0
    if not predicted:
        return 0.0, 0.0, 0.0

    matched_pred = 0
    for pred in predicted:
        if any(pred.matches(g) for g in gold):
            matched_pred += 1
    matched_gold = 0
    for g in gold:
        if any(pred.matches(g) for pred in predicted):
            matched_gold += 1

    precision = matched_pred / len(predicted)
    recall = matched_gold / len(gold)
    if precision + recall == 0:
        f1 = 0.0
    else:
        f1 = 2 * precision * recall / (precision + recall)
    return precision, recall, f1


def grounding_score(
    answer: str,
    context_texts: Sequence[str],
    overlap_threshold: float = GROUNDING_OVERLAP,
) -> float:
    """Fraction of non-refusal claims supported by retrieved context.

    A refused answer with no leftover factual claims scores 1.0 (vacuously
    grounded). Invented claims against empty context score 0.0.
    """
    claims = [c for c in split_claims(answer) if not is_refusal_text(c)]
    if not claims:
        return 1.0
    if not context_texts:
        return 0.0

    context_sets = [tokenize(t) for t in context_texts if t]
    if not context_sets:
        return 0.0

    supported = 0
    for claim in claims:
        words = tokenize(claim)
        if not words:
            continue
        for ctx in context_sets:
            if len(words & ctx) / len(words) > overlap_threshold:
                supported += 1
                break
    return supported / len(claims)


def hallucination_rate(
    predicted: Sequence[SourceRef],
    retrieved: Sequence[CorpusChunk],
) -> float:
    """Share of predicted citations whose file was not in the retrieved set.

    This is the citation-hallucination case: the model names a document
    the retriever never returned.
    """
    if not predicted:
        return 0.0
    retrieved_docs = {c.document_id for c in retrieved if c.document_id}
    retrieved_files = {c.filename.lower() for c in retrieved if c.filename}
    retrieved_ids = {c.id for c in retrieved if c.id}

    hallucinated = 0
    for pred in predicted:
        in_context = False
        if pred.chunk_id and pred.chunk_id in retrieved_ids:
            in_context = True
        if pred.document_id and pred.document_id in retrieved_docs:
            in_context = True
        if pred.filename and pred.filename.lower() in retrieved_files:
            in_context = True
        if not in_context:
            hallucinated += 1
    return hallucinated / len(predicted)


def retrieval_hit_at_k(
    retrieved_ids: Sequence[str],
    gold: Sequence[SourceRef],
    retrieved: Sequence[CorpusChunk] | None = None,
    k: int | None = None,
) -> tuple[float, float]:
    """Return (hit@k, recall@k) of gold sources in the retrieved list.

    Hit is 1.0 if any gold source appears in the top-k results. Recall is
    the fraction of gold sources recovered. Items with no gold sources
    (pure unanswerable) score 1.0 / 1.0 so they do not drag the macro.
    """
    if not gold:
        return 1.0, 1.0

    top = list(retrieved_ids)
    chunks = list(retrieved or [])
    if k is not None:
        top = top[:k]
        chunks = chunks[:k]

    retrieved_refs: list[SourceRef] = []
    seen_ids: set[str] = set()
    for cid in top:
        seen_ids.add(cid)
        retrieved_refs.append(SourceRef(chunk_id=cid))
    for chunk in chunks:
        if chunk.id in seen_ids:
            continue
        retrieved_refs.append(chunk.as_source())

    hits = 0
    for g in gold:
        if any(g.matches(r) or (g.chunk_id and g.chunk_id in seen_ids) for r in retrieved_refs):
            hits += 1
            continue
        # Filename / doc+index match against retrieved chunk objects.
        if any(g.matches(c.as_source()) for c in chunks):
            hits += 1

    recall = hits / len(gold)
    hit = 1.0 if hits else 0.0
    return hit, recall


def mean(values: Iterable[float]) -> float:
    seq = list(values)
    if not seq:
        return 0.0
    return sum(seq) / len(seq)
