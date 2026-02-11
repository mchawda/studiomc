# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""CLaRa Retriever — query → top-k latent vectors + optional snippet retrieval.

Loads the per-collection CLaRa index (numpy), encodes the query with the same
compressor, and returns the top-k chunks by cosine similarity.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from typing import Any

import httpx
import numpy as np

from common.config import INDEXES_DIR, INFERENCE_PORT
from common.database import Database
from common.schemas import (
    ClaraAnswerResponse,
    ClaraQueryResult,
    Citation,
    DocChunk,
)

from clara.compressor import encode_query, load_index

logger = logging.getLogger("clara.retriever")

# ── Retrieval ────────────────────────────────────────────────────


async def retrieve(
    collection_id: str,
    query: str,
    top_k: int = 8,
    include_snippets: bool = False,
) -> ClaraQueryResult:
    """Retrieve top-k chunks for *query* from a collection's CLaRa index.

    Performance target: p95 ≤ 150 ms for top_k=8.
    """
    t0 = time.perf_counter()

    index_dir = INDEXES_DIR / collection_id
    chunk_ids, vectors = load_index(index_dir)

    if len(chunk_ids) == 0:
        return ClaraQueryResult(chunks=[], scores=[], snippets=[])

    # Encode query using same compressor backend
    q_vec = encode_query(query)  # (dims,)

    # Cosine similarity (vectors are already L2-normalised)
    scores = vectors @ q_vec  # (N,)

    # Partial-sort for top-k
    if top_k >= len(scores):
        top_idx = np.argsort(-scores)
    else:
        top_idx = np.argpartition(-scores, top_k)[:top_k]
        top_idx = top_idx[np.argsort(-scores[top_idx])]

    top_chunk_ids = [chunk_ids[i] for i in top_idx]
    top_scores = [float(scores[i]) for i in top_idx]

    # Fetch chunk metadata from DB
    db = await Database.instance()
    placeholders = ",".join("?" for _ in top_chunk_ids)
    rows = await db.fetchall(
        f"SELECT id, document_id, chunk_index, text, token_count, metadata_json "
        f"FROM doc_chunks WHERE id IN ({placeholders})",
        tuple(top_chunk_ids),
    )

    # Build a lookup so we can preserve the ranked order
    row_map: dict[str, Any] = {}
    for r in rows:
        row_map[r["id"]] = r

    chunks: list[DocChunk] = []
    snippets: list[str] = []

    for cid in top_chunk_ids:
        r = row_map.get(cid)
        if r is None:
            continue
        chunks.append(
            DocChunk(
                id=r["id"],
                document_id=r["document_id"],
                chunk_index=r["chunk_index"],
                text=r["text"],
                token_count=r["token_count"],
                metadata_json=r["metadata_json"],
            )
        )
        if include_snippets:
            # Return first 300 chars as the snippet
            snippets.append(r["text"][:300])

    elapsed_ms = (time.perf_counter() - t0) * 1000
    logger.info(
        "retrieve collection=%s top_k=%d elapsed=%.1fms hits=%d",
        collection_id,
        top_k,
        elapsed_ms,
        len(chunks),
    )

    return ClaraQueryResult(
        chunks=chunks,
        scores=top_scores[: len(chunks)],
        snippets=snippets if include_snippets else None,
    )


# ── Answer generation ────────────────────────────────────────────


def _build_answer_prompt(query: str, chunks: list[DocChunk]) -> str:
    """Compose a RAG prompt with numbered sources for the inference model."""
    source_blocks: list[str] = []
    for i, c in enumerate(chunks, 1):
        source_blocks.append(f"[Source {i} | doc={c.document_id} chunk={c.chunk_index}]\n{c.text}\n")

    sources_text = "\n".join(source_blocks)
    return (
        "You are a helpful research assistant. "
        "Answer the user's question using ONLY the sources provided below. "
        "Cite sources inline as [Source N]. "
        "If you cannot answer from the given sources, say so.\n\n"
        f"### Sources\n{sources_text}\n"
        f"### Question\n{query}\n\n"
        "### Answer\n"
    )


def _compute_groundedness(answer: str, chunks: list[DocChunk]) -> float:
    """Estimate groundedness via word-overlap heuristic.

    Returns the proportion of answer sentences that have significant
    word overlap (>30 %) with at least one source chunk.
    """
    import re as _re

    sentences = [s.strip() for s in _re.split(r"[.!?]+", answer) if s.strip()]
    if not sentences:
        return 0.0

    chunk_word_sets = [set(c.text.lower().split()) for c in chunks]
    grounded = 0

    for sent in sentences:
        sent_words = set(sent.lower().split())
        if not sent_words:
            continue
        for cws in chunk_word_sets:
            overlap = len(sent_words & cws) / len(sent_words)
            if overlap > 0.30:
                grounded += 1
                break

    return grounded / len(sentences)


def _extract_citations(
    answer: str,
    chunks: list[DocChunk],
    scores: list[float],
) -> list[Citation]:
    """Parse [Source N] references from the answer and build Citation objects."""
    import re as _re

    citations: list[Citation] = []
    seen: set[int] = set()

    for m in _re.finditer(r"\[Source\s+(\d+)\]", answer):
        idx = int(m.group(1)) - 1  # 1-based → 0-based
        if idx < 0 or idx >= len(chunks) or idx in seen:
            continue
        seen.add(idx)
        c = chunks[idx]
        # Look up filename from DB (best-effort, cached in metadata_json)
        filename = ""
        if c.metadata_json:
            try:
                meta = json.loads(c.metadata_json)
                filename = meta.get("filename", "")
            except (json.JSONDecodeError, TypeError):
                pass

        citations.append(
            Citation(
                document_id=c.document_id,
                filename=filename or c.document_id,
                chunk_index=c.chunk_index,
                snippet=c.text[:300],
                relevance_score=scores[idx] if idx < len(scores) else 0.0,
            )
        )

    # If the model didn't cite anything, fall back to "no sources"
    return citations


async def _resolve_filenames(citations: list[Citation]) -> None:
    """Best-effort: fill in actual filenames from the documents table."""
    if not citations:
        return
    db = await Database.instance()
    doc_ids = list({c.document_id for c in citations})
    placeholders = ",".join("?" for _ in doc_ids)
    rows = await db.fetchall(
        f"SELECT id, filename FROM documents WHERE id IN ({placeholders})",
        tuple(doc_ids),
    )
    name_map = {r["id"]: r["filename"] for r in rows}
    for c in citations:
        if c.document_id in name_map:
            c.filename = name_map[c.document_id]


async def generate_answer(
    collection_id: str,
    query: str,
    top_k: int = 8,
) -> ClaraAnswerResponse:
    """Retrieve context, call inference service, compute groundedness + citations."""
    t0 = time.perf_counter()

    # Step 1: retrieve relevant chunks
    result = await retrieve(collection_id, query, top_k=top_k, include_snippets=False)

    if not result.chunks:
        return ClaraAnswerResponse(
            answer="I could not find any relevant sources to answer this question.",
            citations=[],
            groundedness=0.0,
            metrics={"retrieval_ms": (time.perf_counter() - t0) * 1000},
        )

    retrieval_ms = (time.perf_counter() - t0) * 1000

    # Step 2: build prompt and call inference service
    prompt = _build_answer_prompt(query, result.chunks)

    answer_text = ""
    try:
        async with httpx.AsyncClient(timeout=120.0) as client:
            resp = await client.post(
                f"http://127.0.0.1:{INFERENCE_PORT}/v1/chat/completions",
                json={
                    "messages": [{"role": "user", "content": prompt}],
                    "temperature": 0.3,
                    "max_tokens": 1024,
                },
            )
            resp.raise_for_status()
            data = resp.json()
            answer_text = data["choices"][0]["message"]["content"]
    except Exception as exc:
        logger.error("Inference call failed: %s", exc)
        answer_text = (
            "I retrieved relevant sources but the language model is currently unavailable. "
            "Please try again later."
        )

    generation_ms = (time.perf_counter() - t0) * 1000 - retrieval_ms

    # Step 3: citations + groundedness
    citations = _extract_citations(answer_text, result.chunks, result.scores)
    await _resolve_filenames(citations)

    groundedness = _compute_groundedness(answer_text, result.chunks)

    total_ms = (time.perf_counter() - t0) * 1000

    return ClaraAnswerResponse(
        answer=answer_text,
        citations=citations if citations else [],
        groundedness=round(groundedness, 3),
        metrics={
            "retrieval_ms": round(retrieval_ms, 1),
            "generation_ms": round(generation_ms, 1),
            "total_ms": round(total_ms, 1),
            "chunks_retrieved": len(result.chunks),
        },
    )
