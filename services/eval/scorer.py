# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Offline grounded-answering scorer.

Scores a recorded model output against a gold item. No GPU, no torch,
no CLaRa import. Safe for Core-bundle CI.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Sequence

from eval.metrics import (
    grounding_score,
    hallucination_rate,
    is_refusal_text,
    mean,
    precision_recall,
    resolve_citations,
    retrieval_hit_at_k,
)
from eval.types import (
    CorpusChunk,
    GoldItem,
    ItemScore,
    Prediction,
    SourceRef,
    SuiteScore,
)


def _citation_targets(item: GoldItem) -> list[SourceRef]:
    """Sources the model is expected to cite.

    Unanswerable / must-refuse items expect no citations. Retrieval
    hit-rate still uses ``item.gold_sources`` so partial-evidence
    questions can check that the right chunks were retrieved.
    """
    if item.must_refuse:
        return []
    return list(item.gold_sources)


def score_prediction(
    item: GoldItem,
    prediction: Prediction,
    *,
    k: int = 5,
    corpus: Sequence[CorpusChunk] | None = None,
) -> ItemScore:
    """Score one recorded (or live) prediction against its gold item."""
    retrieved = list(prediction.retrieved)
    if not retrieved and corpus and prediction.retrieved_chunk_ids:
        index = {c.id: c for c in corpus}
        retrieved = [index[cid] for cid in prediction.retrieved_chunk_ids if cid in index]

    citations = resolve_citations(prediction.answer, prediction.citations, retrieved)
    refused = (
        prediction.refused
        if prediction.refused is not None
        else is_refusal_text(prediction.answer)
    )

    gold_for_cites = _citation_targets(item)
    precision, recall, f1 = precision_recall(citations, gold_for_cites)

    context_texts = [c.text for c in retrieved]
    if not context_texts:
        context_texts = [c.snippet for c in citations if c.snippet]

    grounding = grounding_score(prediction.answer, context_texts)
    hallu = hallucination_rate(citations, retrieved)

    hit: float | None = None
    rec_at_k: float | None = None
    if prediction.retrieved_chunk_ids or retrieved:
        hit, rec_at_k = retrieval_hit_at_k(
            prediction.retrieved_chunk_ids,
            item.gold_sources,
            retrieved=retrieved,
            k=k,
        )

    return ItemScore(
        id=item.id,
        kind=item.kind,
        must_refuse=item.must_refuse,
        refused=refused,
        refusal_correct=refused == item.must_refuse,
        grounding=round(grounding, 4),
        citation_precision=round(precision, 4),
        citation_recall=round(recall, 4),
        citation_f1=round(f1, 4),
        citation_hallucination_rate=round(hallu, 4),
        n_gold_sources=len(item.gold_sources),
        n_pred_citations=len(citations),
        n_retrieved=len(retrieved),
        retrieval_hit_at_k=None if hit is None else round(hit, 4),
        retrieval_recall_at_k=None if rec_at_k is None else round(rec_at_k, 4),
    )


def _mean_or_none(values: list[float | None]) -> float | None:
    present = [v for v in values if v is not None]
    if not present:
        return None
    return round(mean(present), 4)


def aggregate(scores: Sequence[ItemScore]) -> SuiteScore:
    """Macro-average a list of item scores."""
    items = list(scores)
    unanswerable = [
        s for s in items if s.must_refuse or s.kind in {"unanswerable", "partial_evidence"}
    ]
    kind_groups: dict[str, list[ItemScore]] = defaultdict(list)
    for s in items:
        kind_groups[s.kind].append(s)

    by_kind = {
        kind: round(mean(s.citation_f1 for s in group), 4)
        for kind, group in sorted(kind_groups.items())
    }

    return SuiteScore(
        items=items,
        n=len(items),
        grounding=round(mean(s.grounding for s in items), 4),
        citation_precision=round(mean(s.citation_precision for s in items), 4),
        citation_recall=round(mean(s.citation_recall for s in items), 4),
        citation_f1=round(mean(s.citation_f1 for s in items), 4),
        citation_hallucination_rate=round(
            mean(s.citation_hallucination_rate for s in items), 4
        ),
        refusal_accuracy=round(mean(1.0 if s.refusal_correct else 0.0 for s in items), 4),
        refusal_accuracy_unanswerable=round(
            mean(1.0 if s.refusal_correct else 0.0 for s in unanswerable), 4
        )
        if unanswerable
        else 1.0,
        retrieval_hit_at_k=_mean_or_none([s.retrieval_hit_at_k for s in items]),
        retrieval_recall_at_k=_mean_or_none([s.retrieval_recall_at_k for s in items]),
        by_kind=by_kind,
    )


def score_dataset(
    gold: Sequence[GoldItem],
    predictions: Sequence[Prediction],
    *,
    k: int = 5,
    corpus: Sequence[CorpusChunk] | None = None,
) -> SuiteScore:
    """Score every gold item that has a matching prediction id."""
    pred_map = {p.id: p for p in predictions}
    missing = [g.id for g in gold if g.id not in pred_map]
    if missing:
        raise KeyError(f"predictions missing gold ids: {missing}")
    scores = [
        score_prediction(item, pred_map[item.id], k=k, corpus=corpus) for item in gold
    ]
    return aggregate(scores)
