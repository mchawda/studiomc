# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Load gold items, corpus chunks, and recorded predictions."""

from __future__ import annotations

import json
from pathlib import Path

from eval.types import CorpusChunk, GoldItem, Prediction

DATA_DIR = Path(__file__).resolve().parent / "data"
DEFAULT_CORPUS = DATA_DIR / "corpus.json"
DEFAULT_GOLD = DATA_DIR / "gold.jsonl"
DEFAULT_RECORDED = DATA_DIR / "recorded.jsonl"


def _read_json(path: Path) -> object:
    return json.loads(path.read_text(encoding="utf-8"))


def _read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            rows.append(json.loads(stripped))
        except json.JSONDecodeError as exc:
            raise ValueError(f"{path}:{line_no}: invalid JSONL") from exc
    return rows


def load_corpus(path: Path | None = None) -> list[CorpusChunk]:
    raw = _read_json(path or DEFAULT_CORPUS)
    if not isinstance(raw, list):
        raise ValueError("corpus JSON must be a list of chunks")
    chunks = [CorpusChunk.from_dict(row) for row in raw]
    missing = [c for c in chunks if not c.id]
    if missing:
        raise ValueError("every corpus chunk needs an id")
    return chunks


def load_gold(path: Path | None = None) -> list[GoldItem]:
    rows = _read_jsonl(path or DEFAULT_GOLD)
    items = [GoldItem.from_dict(row) for row in rows]
    ids = [i.id for i in items]
    if len(ids) != len(set(ids)):
        raise ValueError("gold item ids must be unique")
    return items


def load_predictions(path: Path | None = None) -> list[Prediction]:
    rows = _read_jsonl(path or DEFAULT_RECORDED)
    return [Prediction.from_dict(row) for row in rows]


def corpus_by_id(chunks: list[CorpusChunk]) -> dict[str, CorpusChunk]:
    return {c.id: c for c in chunks}


def attach_retrieved(
    prediction: Prediction,
    corpus: list[CorpusChunk],
) -> Prediction:
    """Fill ``prediction.retrieved`` from ids when only ids were recorded."""
    if prediction.retrieved:
        return prediction
    index = corpus_by_id(corpus)
    prediction.retrieved = [
        index[cid] for cid in prediction.retrieved_chunk_ids if cid in index
    ]
    return prediction
