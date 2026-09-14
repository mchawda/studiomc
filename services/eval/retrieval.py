# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Lexical (and optional CLaRa-hash) retrieval for the eval harness.

The default path is BM25 over the fixture corpus. It never imports torch
or CLaRa. ``retrieve_clara_hash`` lazily uses the Core TF-IDF compressor
when the caller opts in; that path still stays Pro-pack free.
"""

from __future__ import annotations

import math
import re
from collections import Counter
from collections.abc import Sequence

from eval.types import CorpusChunk

_TOKEN_RE = re.compile(r"[a-z0-9]+")

# BM25 parameters (standard TREC defaults).
_K1 = 1.2
_B = 0.75


def tokenize_query(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower())


class LexicalIndex:
    """In-memory BM25 index over eval corpus chunks."""

    def __init__(self, chunks: Sequence[CorpusChunk]) -> None:
        self.chunks = list(chunks)
        self._docs: list[list[str]] = [tokenize_query(c.text) for c in self.chunks]
        self._tfs: list[Counter[str]] = [Counter(doc) for doc in self._docs]
        self._df: Counter[str] = Counter()
        for tf in self._tfs:
            for term in tf:
                self._df[term] += 1
        self._n = len(self.chunks)
        lengths = [len(doc) for doc in self._docs]
        self._avgdl = (sum(lengths) / self._n) if self._n else 0.0

    def _idf(self, term: str) -> float:
        df = self._df.get(term, 0)
        return math.log((self._n - df + 0.5) / (df + 0.5) + 1.0)

    def search(self, query: str, top_k: int = 5) -> list[tuple[CorpusChunk, float]]:
        tokens = tokenize_query(query)
        if not tokens or not self.chunks:
            return []
        scores = [0.0] * self._n
        for i, tf in enumerate(self._tfs):
            dl = len(self._docs[i]) or 1
            score = 0.0
            for term in tokens:
                freq = tf.get(term, 0)
                if not freq:
                    continue
                idf = self._idf(term)
                denom = freq + _K1 * (1.0 - _B + _B * dl / max(self._avgdl, 1e-9))
                score += idf * (freq * (_K1 + 1.0)) / denom
            scores[i] = score
        ranked = sorted(range(self._n), key=lambda i: scores[i], reverse=True)
        out: list[tuple[CorpusChunk, float]] = []
        for i in ranked:
            if scores[i] <= 0:
                continue
            out.append((self.chunks[i], scores[i]))
            if len(out) >= top_k:
                break
        return out


def retrieve_lexical(
    query: str,
    chunks: Sequence[CorpusChunk],
    top_k: int = 5,
) -> list[CorpusChunk]:
    """Return top-k chunks by BM25. Safe for Core-bundle / CI."""
    return [chunk for chunk, _score in LexicalIndex(chunks).search(query, top_k=top_k)]


def retrieve_clara_hash(
    query: str,
    chunks: Sequence[CorpusChunk],
    top_k: int = 5,
) -> list[CorpusChunk] | None:
    """Score the fixture corpus with CLaRa's Core TF-IDF hash encoder.

    Returns None if CLaRa or numpy cannot be imported so the runner can
    fall back to BM25. This function is never imported by the offline
    scorer.
    """
    try:
        from clara.compressor import encode_texts
    except Exception:
        return None

    texts = [c.text for c in chunks]
    if not texts:
        return []
    try:
        matrix = encode_texts([query, *texts])
    except Exception:
        return None

    query_vec = matrix[0]
    doc_vecs = matrix[1:]
    # Cosine: encode_texts L2-normalises on the TF-IDF path.
    scores = doc_vecs @ query_vec
    order = sorted(range(len(chunks)), key=lambda i: float(scores[i]), reverse=True)
    return [chunks[i] for i in order[:top_k]]
