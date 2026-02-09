"""CLaRa Compressor — creates latent vectors from document chunks.

Phase 1 strategy:
  1. Try sentence-transformers (high-quality embeddings).
  2. Fall back to TF-IDF bag-of-words if sentence-transformers is unavailable.

Vectors are persisted to the `clara_vectors` table (as numpy byte blobs)
and aggregated into per-collection index files at INDEXES_DIR/<cid>/clara_index.npz.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    from numpy.typing import NDArray

logger = logging.getLogger("clara.compressor")

# ── Backend detection ────────────────────────────────────────────

_USE_SBERT = False
_sbert_model = None

try:
    from sentence_transformers import SentenceTransformer  # type: ignore[import-untyped]

    _USE_SBERT = True
    logger.info("sentence-transformers available — using neural embeddings")
except ImportError:
    logger.info("sentence-transformers not installed — using TF-IDF fallback")

COMPRESSOR_VERSION = "clara-v0.1-sbert" if _USE_SBERT else "clara-v0.1-tfidf"

# ── TF-IDF fallback ────────────────────────────────────────────────

_TFIDF_DIM = 512
_TOKEN_RE = re.compile(r"[a-z0-9]+")


def _tokenize(text: str) -> list[str]:
    return _TOKEN_RE.findall(text.lower())


class _TfidfVectorizer:
    """Minimal TF-IDF vectorizer that maps text → fixed-dim vector via hashing."""

    def __init__(self, dim: int = _TFIDF_DIM) -> None:
        self.dim = dim

    def encode(self, texts: list[str]) -> NDArray[np.float32]:
        vecs = np.zeros((len(texts), self.dim), dtype=np.float32)
        for i, text in enumerate(texts):
            tokens = _tokenize(text)
            if not tokens:
                continue
            # Hashing trick — distribute token counts into fixed buckets
            for tok in tokens:
                bucket = hash(tok) % self.dim
                vecs[i, bucket] += 1.0
            # L2-normalise so cosine similarity = dot product
            norm = np.linalg.norm(vecs[i])
            if norm > 0:
                vecs[i] /= norm
        return vecs


_tfidf = _TfidfVectorizer()

# ── Public API ──────────────────────────────────────────────────


def _get_sbert_model() -> SentenceTransformer:  # type: ignore[name-defined]
    """Lazy-load the sentence-transformer model."""
    global _sbert_model
    if _sbert_model is None:
        _sbert_model = SentenceTransformer("all-MiniLM-L6-v2")
        logger.info("Loaded SentenceTransformer all-MiniLM-L6-v2")
    return _sbert_model


def get_dims() -> int:
    """Return the dimensionality of vectors produced by the active backend."""
    if _USE_SBERT:
        return _get_sbert_model().get_sentence_embedding_dimension()  # 384
    return _TFIDF_DIM


def encode_texts(texts: list[str]) -> NDArray[np.float32]:
    """Encode a batch of texts into normalised latent vectors.

    Returns
    -------
    np.ndarray of shape (len(texts), dims) with dtype float32.
    """
    if not texts:
        return np.empty((0, get_dims()), dtype=np.float32)

    if _USE_SBERT:
        model = _get_sbert_model()
        vecs: NDArray[np.float32] = model.encode(
            texts,
            batch_size=64,
            show_progress_bar=False,
            normalize_embeddings=True,
        )
        return vecs.astype(np.float32)

    return _tfidf.encode(texts)


def encode_query(query: str) -> NDArray[np.float32]:
    """Encode a single query string into a latent vector (1, dims)."""
    return encode_texts([query])[0]


# ── Source-offset mapping helpers ────────────────────────────────


def compute_source_offsets(text: str) -> str:
    """Compute character-level source offset mapping (JSON string).

    For Phase 1 we simply record sentence boundaries so citations can
    point to the exact region of the chunk that was matched.
    """
    # Naive sentence splitter
    sentences: list[dict[str, int]] = []
    start = 0
    for m in re.finditer(r"[.!?]+\s*", text):
        end = m.end()
        sentences.append({"start": start, "end": end})
        start = end
    if start < len(text):
        sentences.append({"start": start, "end": len(text)})
    return json.dumps(sentences)


# ── Index I/O helpers ────────────────────────────────────────────


def save_index(
    index_dir: Path,
    chunk_ids: list[str],
    vectors: NDArray[np.float32],
) -> Path:
    """Persist a collection's CLaRa index to disk.

    File layout: ``<index_dir>/clara_index.npz``
    Contains:
      - ``vectors``: (N, dims) float32 array
      - ``chunk_ids``: (N,) unicode array
    """
    index_dir.mkdir(parents=True, exist_ok=True)
    path = index_dir / "clara_index.npz"
    np.savez_compressed(
        str(path),
        vectors=vectors,
        chunk_ids=np.array(chunk_ids, dtype="U"),
    )
    logger.info("Saved CLaRa index to %s  (%d vectors, %d dims)", path, len(chunk_ids), vectors.shape[1])
    return path


def load_index(index_dir: Path) -> tuple[list[str], NDArray[np.float32]]:
    """Load a persisted CLaRa index.

    Returns
    -------
    (chunk_ids, vectors) — list of chunk id strings, (N, dims) array.
    """
    path = index_dir / "clara_index.npz"
    data = np.load(str(path), allow_pickle=False)
    chunk_ids = data["chunk_ids"].tolist()
    vectors: NDArray[np.float32] = data["vectors"].astype(np.float32)
    return chunk_ids, vectors
