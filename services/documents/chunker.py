"""Text chunking — split extracted text into overlapping chunks of 500-1000 tokens.

Token estimation uses word_count * 0.75 (avoids a hard dependency on tiktoken).
Chunks are stored in the doc_chunks table and as DOCS_DIR/<doc_id>/chunks.jsonl.
"""

from __future__ import annotations

import json
import uuid
from pathlib import Path

import aiofiles

from common.config import DOCS_DIR
from common.database import Database


# ── Configuration ────────────────────────────────────────────────

MIN_TOKENS = 500
MAX_TOKENS = 1000
OVERLAP_TOKENS = 50

# Rough conversion factor: 1 word ≈ 1.33 tokens → 1 token ≈ 0.75 words
WORDS_PER_TOKEN = 0.75


def _estimate_tokens(text: str) -> int:
    """Estimate token count from word count."""
    word_count = len(text.split())
    return max(1, int(word_count / WORDS_PER_TOKEN))


def _words_for_tokens(n_tokens: int) -> int:
    """Convert a token count to an approximate word count."""
    return max(1, int(n_tokens * WORDS_PER_TOKEN))


# ── Core chunking logic ─────────────────────────────────────────


def chunk_text(text: str) -> list[dict]:
    """Split *text* into overlapping chunks.

    Returns a list of dicts:
        {"chunk_index": int, "text": str, "token_count": int}
    """
    words = text.split()
    if not words:
        return []

    target_words = _words_for_tokens(MAX_TOKENS)   # words per chunk
    overlap_words = _words_for_tokens(OVERLAP_TOKENS)
    step = max(1, target_words - overlap_words)

    chunks: list[dict] = []
    idx = 0
    start = 0

    while start < len(words):
        end = min(start + target_words, len(words))
        chunk_words = words[start:end]
        chunk_str = " ".join(chunk_words)
        token_est = _estimate_tokens(chunk_str)

        chunks.append({
            "chunk_index": idx,
            "text": chunk_str,
            "token_count": token_est,
        })
        idx += 1

        # Advance by step; if the remaining words fit within MAX_TOKENS we stop
        start += step
        if end == len(words):
            break

    return chunks


# ── Persistence ──────────────────────────────────────────────────


async def chunk_and_store(doc_id: str, text: str) -> list[dict]:
    """Chunk the text, write chunks.jsonl, and insert rows into doc_chunks.

    Returns the list of chunk dicts (with ``id`` added).
    """
    raw_chunks = chunk_text(text)

    db = await Database.instance()

    # Assign UUIDs
    for c in raw_chunks:
        c["id"] = uuid.uuid4().hex
        c["document_id"] = doc_id

    # Write JSONL file
    doc_dir = DOCS_DIR / doc_id
    doc_dir.mkdir(parents=True, exist_ok=True)
    jsonl_path = doc_dir / "chunks.jsonl"

    async with aiofiles.open(jsonl_path, "w", encoding="utf-8") as f:
        for c in raw_chunks:
            line = json.dumps({
                "id": c["id"],
                "chunk_index": c["chunk_index"],
                "text": c["text"],
                "token_count": c["token_count"],
            })
            await f.write(line + "\n")

    # Insert into database
    await db.executemany(
        """INSERT INTO doc_chunks (id, document_id, chunk_index, text, token_count)
           VALUES (?, ?, ?, ?, ?)""",
        [
            (c["id"], c["document_id"], c["chunk_index"], c["text"], c["token_count"])
            for c in raw_chunks
        ],
    )
    await db.commit()

    return raw_chunks
