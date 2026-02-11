"""CLaRa Compressor — creates latent vectors from document chunks.

Phase 1 strategy:
  1. Try sentence-transformers (high-quality embeddings).
  2. Fall back to TF-IDF bag-of-words if sentence-transformers is unavailable.

Phase 2 enhancement:
  3. LatentCompressor — PCA / random-projection dimensionality reduction
     that achieves 32–64× compression on the embedding vectors while
     preserving retrieval quality.  Compressed representations are stored
     alongside standard chunks for fast search in latent space.

Vectors are persisted to the `clara_vectors` table (as numpy byte blobs)
and aggregated into per-collection index files at INDEXES_DIR/<cid>/clara_index.npz.
"""

from __future__ import annotations

import json
import logging
import re
import time
from dataclasses import dataclass, field
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


# ═══════════════════════════════════════════════════════════════════
# Phase 2 — LatentCompressor: compression-native storage & search
# ═══════════════════════════════════════════════════════════════════


@dataclass
class CompressionStats:
    """Tracks compression ratio and quality metrics."""

    original_dims: int = 0
    compressed_dims: int = 0
    compression_ratio: float = 1.0
    num_vectors: int = 0
    fit_time_ms: int = 0
    compress_time_ms: int = 0
    method: str = "none"
    explained_variance_ratio: float | None = None

    @property
    def space_savings_pct(self) -> float:
        """Percentage of storage saved (0–100)."""
        if self.original_dims == 0:
            return 0.0
        return (1.0 - self.compressed_dims / self.original_dims) * 100.0


class LatentCompressor:
    """Dimensionality-reduction compressor for CLaRa embeddings.

    Uses PCA (when sklearn is available) or Gaussian random projection
    as a lightweight fallback. Achieves 32–64× compression on typical
    384-dim SBERT embeddings (target: 6–12 dimensions).

    Usage::

        lc = LatentCompressor(target_dims=12, method="pca")
        lc.fit(full_vectors)                      # learn projection
        compressed = lc.compress(full_vectors)     # (N, 12)
        results = lc.decompress_and_search(query_vec, compressed, chunk_ids, top_k=5)

    The compressor is fully backward-compatible: if not fitted, all
    public methods fall back to operating on the original vectors.
    """

    # Supported methods
    METHOD_PCA = "pca"
    METHOD_RANDOM = "random_projection"

    def __init__(
        self,
        target_dims: int = 12,
        method: str = "pca",
    ) -> None:
        if target_dims < 2:
            raise ValueError("target_dims must be >= 2")
        if method not in (self.METHOD_PCA, self.METHOD_RANDOM):
            raise ValueError(f"Unknown method '{method}', use 'pca' or 'random_projection'")

        self.target_dims = target_dims
        self.method = method
        self.stats = CompressionStats(method=method)

        # Projection state (set after fit)
        self._projection_matrix: NDArray[np.float32] | None = None  # (original_dims, target_dims)
        self._mean: NDArray[np.float32] | None = None  # (original_dims,) — PCA only
        self._fitted = False
        self._original_dims: int = 0

    @property
    def is_fitted(self) -> bool:
        """True if the compressor has been fitted to data."""
        return self._fitted

    # ── Fitting ───────────────────────────────────────────────────────

    def fit(self, vectors: NDArray[np.float32]) -> CompressionStats:
        """Learn the projection from full-dimensional embedding space.

        For PCA: computes the top-k principal components via SVD.
        For random projection: generates a Gaussian random matrix
        (Johnson–Lindenstrauss lemma guarantees distance preservation).

        Args:
            vectors: (N, D) array of full-dimensional embeddings.
                     N must be >= target_dims for PCA.

        Returns:
            CompressionStats with fit details.
        """
        if vectors.ndim != 2 or vectors.shape[0] == 0:
            raise ValueError("vectors must be a non-empty 2D array")

        n_samples, original_dims = vectors.shape
        self._original_dims = original_dims

        # Clamp target_dims to not exceed original dims
        effective_target = min(self.target_dims, original_dims)

        t0 = time.perf_counter()

        if self.method == self.METHOD_PCA:
            self._fit_pca(vectors, effective_target)
        else:
            self._fit_random_projection(original_dims, effective_target)

        fit_ms = int((time.perf_counter() - t0) * 1000)

        self._fitted = True
        self.stats = CompressionStats(
            original_dims=original_dims,
            compressed_dims=effective_target,
            compression_ratio=original_dims / max(effective_target, 1),
            num_vectors=n_samples,
            fit_time_ms=fit_ms,
            method=self.method,
            explained_variance_ratio=(
                self._explained_variance if hasattr(self, "_explained_variance") else None
            ),
        )

        logger.info(
            "LatentCompressor fitted: %s %dD → %dD (%.1f× compression, %.1f%% space saved, %dms)",
            self.method,
            original_dims,
            effective_target,
            self.stats.compression_ratio,
            self.stats.space_savings_pct,
            fit_ms,
        )
        return self.stats

    def _fit_pca(self, vectors: NDArray[np.float32], target: int) -> None:
        """Compute PCA projection via truncated SVD (no sklearn needed)."""
        n_samples = vectors.shape[0]
        # Center the data
        self._mean = vectors.mean(axis=0).astype(np.float32)
        centered = vectors - self._mean

        if n_samples < target:
            logger.warning(
                "Only %d samples for %d PCA components — clamping to %d",
                n_samples, target, n_samples,
            )
            target = n_samples

        # Truncated SVD: compute only top-k singular vectors
        # For N < D, it's more efficient to compute SVD of the centered matrix
        # U, S, Vt = svd(centered) — Vt[:k] are the principal components
        try:
            # Use numpy's full SVD (works for any size; we only keep top-k)
            _, s_values, vt = np.linalg.svd(centered, full_matrices=False)
            # Principal component directions: (target, D)
            components = vt[:target].astype(np.float32)
            # Projection matrix: (D, target)
            self._projection_matrix = components.T

            # Compute explained variance ratio for stats
            total_var = (s_values ** 2).sum()
            explained_var = (s_values[:target] ** 2).sum()
            self._explained_variance = float(explained_var / max(total_var, 1e-10))
        except np.linalg.LinAlgError:
            logger.warning("SVD failed, falling back to random projection")
            self._mean = None
            self._fit_random_projection(vectors.shape[1], target)
            self.method = self.METHOD_RANDOM

    def _fit_random_projection(self, original_dims: int, target: int) -> None:
        """Generate a Gaussian random projection matrix.

        By the Johnson–Lindenstrauss lemma, pairwise distances are
        approximately preserved with high probability when projecting
        to O(log(n) / eps^2) dimensions.
        """
        rng = np.random.default_rng(seed=42)  # deterministic for reproducibility
        # Gaussian random matrix scaled by 1/sqrt(target)
        matrix = rng.standard_normal((original_dims, target)).astype(np.float32)
        matrix /= np.sqrt(target)
        # Orthonormalize columns via QR for better distance preservation
        q, _ = np.linalg.qr(matrix)
        self._projection_matrix = q[:, :target].astype(np.float32)
        self._mean = None

    # ── Compression ──────────────────────────────────────────────────

    def compress(self, vectors: NDArray[np.float32]) -> NDArray[np.float32]:
        """Project full-dimensional vectors into compressed latent space.

        Args:
            vectors: (N, D) full-dimensional embeddings.

        Returns:
            (N, target_dims) compressed vectors, L2-normalized.
        """
        if not self._fitted or self._projection_matrix is None:
            logger.warning("LatentCompressor not fitted — returning original vectors")
            return vectors

        t0 = time.perf_counter()

        if self._mean is not None:
            centered = vectors - self._mean
        else:
            centered = vectors

        # Project: (N, D) @ (D, target) -> (N, target)
        compressed = centered @ self._projection_matrix

        # L2-normalize for cosine similarity in compressed space
        norms = np.linalg.norm(compressed, axis=1, keepdims=True)
        norms = np.maximum(norms, 1e-10)
        compressed = (compressed / norms).astype(np.float32)

        compress_ms = int((time.perf_counter() - t0) * 1000)
        self.stats.compress_time_ms = compress_ms

        return compressed

    def compress_query(self, query_vec: NDArray[np.float32]) -> NDArray[np.float32]:
        """Compress a single query vector into latent space.

        Args:
            query_vec: (D,) full-dimensional query embedding.

        Returns:
            (target_dims,) compressed query vector, L2-normalized.
        """
        if query_vec.ndim == 1:
            query_vec = query_vec.reshape(1, -1)
        return self.compress(query_vec)[0]

    # ── Search in compressed space ───────────────────────────────────

    def decompress_and_search(
        self,
        query_vec: NDArray[np.float32],
        compressed_vectors: NDArray[np.float32],
        chunk_ids: list[str],
        top_k: int = 5,
        full_vectors: NDArray[np.float32] | None = None,
        rerank_factor: int = 3,
    ) -> list[dict]:
        """Search for the most relevant chunks in compressed latent space.

        Two-stage retrieval:
          1. **Fast pass** — cosine similarity in compressed space to get
             ``top_k * rerank_factor`` candidates.
          2. **Rerank pass** (optional) — if ``full_vectors`` is provided,
             rerank candidates using full-dimensional cosine similarity
             for higher precision.

        Args:
            query_vec:          (D,) full-dimensional query embedding.
            compressed_vectors: (N, target_dims) compressed index.
            chunk_ids:          Chunk IDs aligned with compressed_vectors.
            top_k:              Number of results to return.
            full_vectors:       Optional (N, D) full vectors for reranking.
            rerank_factor:      How many extra candidates to fetch for reranking.

        Returns:
            List of dicts: ``[{"chunk_id": ..., "score": ..., "rank": ...}, ...]``
            sorted by descending relevance score.
        """
        if not self._fitted or self._projection_matrix is None:
            # Fallback: operate on whatever vectors are available
            logger.warning("LatentCompressor not fitted — using brute-force on provided vectors")
            return self._brute_force_search(query_vec, compressed_vectors, chunk_ids, top_k)

        # Compress the query
        q_compressed = self.compress_query(query_vec)

        # Stage 1: fast cosine similarity in compressed space
        # compressed_vectors is already L2-normalized, as is q_compressed
        scores = compressed_vectors @ q_compressed  # (N,)

        # Number of candidates for reranking
        n_candidates = min(top_k * rerank_factor, len(chunk_ids))
        top_indices = np.argpartition(scores, -n_candidates)[-n_candidates:]
        top_indices = top_indices[np.argsort(scores[top_indices])[::-1]]

        # Stage 2: rerank with full vectors if available
        if full_vectors is not None and full_vectors.shape[0] == len(chunk_ids):
            # Rerank the candidates using full-dimensional similarity
            candidate_full = full_vectors[top_indices]
            q_norm = query_vec / max(np.linalg.norm(query_vec), 1e-10)
            rerank_scores = candidate_full @ q_norm
            rerank_order = np.argsort(rerank_scores)[::-1][:top_k]
            final_indices = top_indices[rerank_order]
            final_scores = rerank_scores[rerank_order]
        else:
            final_indices = top_indices[:top_k]
            final_scores = scores[final_indices]

        results = []
        for rank, (idx, score) in enumerate(zip(final_indices, final_scores)):
            results.append({
                "chunk_id": chunk_ids[idx],
                "score": float(score),
                "rank": rank,
            })
        return results

    @staticmethod
    def _brute_force_search(
        query_vec: NDArray[np.float32],
        vectors: NDArray[np.float32],
        chunk_ids: list[str],
        top_k: int,
    ) -> list[dict]:
        """Fallback brute-force cosine search (no compression)."""
        q_norm = query_vec / max(np.linalg.norm(query_vec), 1e-10)
        scores = vectors @ q_norm
        top_k = min(top_k, len(chunk_ids))
        top_indices = np.argpartition(scores, -top_k)[-top_k:]
        top_indices = top_indices[np.argsort(scores[top_indices])[::-1]]
        return [
            {"chunk_id": chunk_ids[i], "score": float(scores[i]), "rank": rank}
            for rank, i in enumerate(top_indices)
        ]

    # ── Persistence ──────────────────────────────────────────────────

    def save(self, path: Path) -> None:
        """Persist the fitted compressor state to disk.

        Saves: projection matrix, mean vector (PCA), method, target_dims.
        """
        if not self._fitted or self._projection_matrix is None:
            raise RuntimeError("Cannot save unfitted LatentCompressor")

        path.parent.mkdir(parents=True, exist_ok=True)
        save_dict: dict[str, object] = {
            "projection_matrix": self._projection_matrix,
            "method": np.array([self.method], dtype="U"),
            "target_dims": np.array([self.target_dims]),
            "original_dims": np.array([self._original_dims]),
        }
        if self._mean is not None:
            save_dict["mean"] = self._mean

        np.savez_compressed(str(path), **save_dict)
        logger.info("Saved LatentCompressor to %s", path)

    @classmethod
    def load(cls, path: Path) -> LatentCompressor:
        """Load a previously fitted compressor from disk."""
        data = np.load(str(path), allow_pickle=False)

        method = str(data["method"][0])
        target_dims = int(data["target_dims"][0])

        compressor = cls(target_dims=target_dims, method=method)
        compressor._projection_matrix = data["projection_matrix"].astype(np.float32)
        compressor._original_dims = int(data["original_dims"][0])
        compressor._mean = data["mean"].astype(np.float32) if "mean" in data else None
        compressor._fitted = True

        original_dims = compressor._original_dims
        compressor.stats = CompressionStats(
            original_dims=original_dims,
            compressed_dims=target_dims,
            compression_ratio=original_dims / max(target_dims, 1),
            method=method,
        )

        logger.info(
            "Loaded LatentCompressor from %s: %s %dD → %dD (%.1f×)",
            path, method, original_dims, target_dims, compressor.stats.compression_ratio,
        )
        return compressor

    # ── Report ────────────────────────────────────────────────────────

    def report(self) -> dict:
        """Return a human-readable compression report."""
        return {
            "fitted": self._fitted,
            "method": self.method,
            "original_dims": self.stats.original_dims,
            "compressed_dims": self.stats.compressed_dims,
            "compression_ratio": round(self.stats.compression_ratio, 1),
            "space_savings_pct": round(self.stats.space_savings_pct, 1),
            "explained_variance_ratio": (
                round(self.stats.explained_variance_ratio, 4)
                if self.stats.explained_variance_ratio is not None
                else None
            ),
            "num_vectors_at_fit": self.stats.num_vectors,
            "fit_time_ms": self.stats.fit_time_ms,
            "last_compress_time_ms": self.stats.compress_time_ms,
        }


# ── Compressed index I/O helpers ─────────────────────────────────


def save_compressed_index(
    index_dir: Path,
    chunk_ids: list[str],
    full_vectors: NDArray[np.float32],
    compressor: LatentCompressor,
) -> Path:
    """Persist a compressed CLaRa index alongside the full index.

    Saves:
      - ``clara_compressed_index.npz`` with compressed vectors and chunk_ids
      - ``clara_compressor.npz`` with the fitted compressor state

    The full index is also saved via the standard ``save_index`` for
    backward compatibility.
    """
    index_dir.mkdir(parents=True, exist_ok=True)

    # Save full index for backward compat
    save_index(index_dir, chunk_ids, full_vectors)

    # Compress and save
    compressed = compressor.compress(full_vectors)
    compressed_path = index_dir / "clara_compressed_index.npz"
    np.savez_compressed(
        str(compressed_path),
        vectors=compressed,
        chunk_ids=np.array(chunk_ids, dtype="U"),
    )

    # Save compressor state
    compressor_path = index_dir / "clara_compressor.npz"
    compressor.save(compressor_path)

    logger.info(
        "Saved compressed CLaRa index to %s  (%d vectors, %dD → %dD, %.1f× compression)",
        compressed_path,
        len(chunk_ids),
        full_vectors.shape[1],
        compressed.shape[1],
        compressor.stats.compression_ratio,
    )
    return compressed_path


def load_compressed_index(
    index_dir: Path,
) -> tuple[list[str], NDArray[np.float32], NDArray[np.float32], LatentCompressor]:
    """Load a compressed CLaRa index and its compressor.

    Returns
    -------
    (chunk_ids, full_vectors, compressed_vectors, compressor)
    """
    # Load full vectors (backward compat path)
    chunk_ids, full_vectors = load_index(index_dir)

    # Load compressed vectors
    compressed_path = index_dir / "clara_compressed_index.npz"
    data = np.load(str(compressed_path), allow_pickle=False)
    compressed_vectors: NDArray[np.float32] = data["vectors"].astype(np.float32)

    # Load compressor
    compressor_path = index_dir / "clara_compressor.npz"
    compressor = LatentCompressor.load(compressor_path)

    return chunk_ids, full_vectors, compressed_vectors, compressor
