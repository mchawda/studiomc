# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Stub / fake generator used by the live eval path.

Does not call a language model. It pastes a supported span from the
retrieved chunks and cites ``[Source N]`` the way CLaRa prompts the
real model to. It refuses only when retrieval is empty or the query
has essentially no lexical overlap with the context.

Refusal quality for the moat is measured on recorded model outputs
via the offline scorer, not this stub.
"""

from __future__ import annotations

from collections.abc import Sequence

from eval.retrieval import tokenize_query
from eval.types import CorpusChunk, Prediction, SourceRef

REFUSE_OVERLAP = 0.08

REFUSAL_ANSWER = (
    "I don't know. The retrieved sources do not contain enough evidence "
    "to answer this question."
)


def _best_overlap(question: str, chunk: CorpusChunk) -> float:
    q = set(tokenize_query(question))
    d = set(tokenize_query(chunk.text))
    if not q:
        return 0.0
    return len(q & d) / len(q)


def _first_sentence(text: str) -> str:
    for sep in (". ", "? ", "! "):
        idx = text.find(sep)
        if idx > 40:
            return text[: idx + 1].strip()
    return text[:240].strip()


def generate_stub(
    item_id: str,
    question: str,
    retrieved: Sequence[CorpusChunk],
    refuse_overlap: float = REFUSE_OVERLAP,
    index_chunks: Sequence[CorpusChunk] | None = None,
) -> Prediction:
    """Produce a deterministic cited answer or a refusal.

    ``index_chunks`` is accepted for API compatibility with the runner
    (corpus-level IDF) but is not required by this lexical stub.
    """
    del index_chunks  # unused; kept so runner / tests can pass corpus
    retrieved_ids = [c.id for c in retrieved]
    if not retrieved:
        return Prediction(
            id=item_id,
            answer=REFUSAL_ANSWER,
            citations=[],
            retrieved_chunk_ids=[],
            retrieved=[],
            refused=True,
        )

    scored = [(_best_overlap(question, chunk), i, chunk) for i, chunk in enumerate(retrieved)]
    scored.sort(key=lambda row: row[0], reverse=True)
    best_overlap, _best_i, _best_chunk = scored[0]

    if best_overlap < refuse_overlap:
        return Prediction(
            id=item_id,
            answer=REFUSAL_ANSWER,
            citations=[],
            retrieved_chunk_ids=retrieved_ids,
            retrieved=list(retrieved),
            refused=True,
        )

    used: list[tuple[int, CorpusChunk]] = []
    for overlap, idx, chunk in scored:
        if overlap < refuse_overlap:
            continue
        used.append((idx, chunk))
        # Multi-hop questions usually contain "and"; otherwise cite the best span only.
        limit = 2 if " and " in question.lower() else 1
        if len(used) >= limit:
            break

    parts: list[str] = []
    citations: list[SourceRef] = []
    for idx, chunk in used:
        source_n = idx + 1
        parts.append(f"{_first_sentence(chunk.text)} [Source {source_n}]")
        citations.append(chunk.as_source())

    return Prediction(
        id=item_id,
        answer=" ".join(parts),
        citations=citations,
        retrieved_chunk_ids=retrieved_ids,
        retrieved=list(retrieved),
        refused=False,
    )
