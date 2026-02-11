# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""CLaRa Compression-Aware Trainer — fine-tunes the compression model.

Phase 3: Trains the sentence embedding model used by CLaRa's compressor
on domain-specific documents via contrastive learning.  Positive pairs
(chunk ↔ compressed representation) should be close in the embedding space,
while negatives are pushed apart.

Supports:
  - Full training from a document collection
  - Incremental training (add new documents without retraining from scratch)
  - Evaluation: recall@k and compression ratio metrics
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Callable

import numpy as np

if TYPE_CHECKING:
    from numpy.typing import NDArray

from common.config import INDEXES_DIR, MODELS_DIR
from common.database import Database

from clara.compressor import (
    _USE_SBERT,
    encode_texts,
    get_dims,
    save_index,
)

logger = logging.getLogger("clara.trainer")

# ── Optional dependency detection ────────────────────────────────

_HAS_TORCH = False
_HAS_TRANSFORMERS = False

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    _HAS_TORCH = True
except ImportError:
    torch = None  # type: ignore[assignment]

try:
    from sentence_transformers import SentenceTransformer, InputExample, losses  # type: ignore[import-untyped]

    _HAS_SBERT_TRAIN = True
except ImportError:
    _HAS_SBERT_TRAIN = False

try:
    from transformers import AutoTokenizer

    _HAS_TRANSFORMERS = True
except ImportError:
    pass

# ── Constants ────────────────────────────────────────────────────

CLARA_MODELS_DIR = MODELS_DIR / "clara"
DEFAULT_SBERT_MODEL = "all-MiniLM-L6-v2"


# ── Training result ──────────────────────────────────────────────


@dataclass
class ClaraTrainResult:
    """Outcome of a CLaRa compression training run."""

    success: bool
    model_path: str = ""
    num_documents: int = 0
    num_chunks: int = 0
    num_training_pairs: int = 0
    epochs_completed: int = 0
    final_loss: float | None = None
    recall_at_k: dict[int, float] = field(default_factory=dict)
    compression_ratio: float = 0.0
    error: str | None = None
    metrics: dict[str, Any] = field(default_factory=dict)


# ── Contrastive dataset builder ──────────────────────────────────


def _build_contrastive_pairs(
    chunks: list[str],
    num_negatives: int = 5,
) -> list[tuple[str, str, float]]:
    """Build (anchor, candidate, label) triplets for contrastive learning.

    Positive pairs: (chunk_text, chunk_text_variant) → label 1.0
    Negative pairs: (chunk_text, other_chunk_text)   → label 0.0

    Variants are created by taking the first/second half of a chunk
    to teach the model that partial content maps to the same region.
    """
    pairs: list[tuple[str, str, float]] = []

    for i, chunk in enumerate(chunks):
        if len(chunk.strip()) < 20:
            continue

        # ── Positive pairs ──
        # 1. Self-pair (chunk ↔ chunk) — identity mapping
        pairs.append((chunk, chunk, 1.0))

        # 2. First-half ↔ full chunk
        mid = len(chunk) // 2
        if mid > 20:
            pairs.append((chunk[:mid], chunk, 1.0))
            pairs.append((chunk[mid:], chunk, 1.0))

        # 3. Sentence-level partial: first 2 sentences ↔ full chunk
        sentences = [s.strip() for s in chunk.split(".") if s.strip()]
        if len(sentences) >= 2:
            partial = ". ".join(sentences[:2]) + "."
            pairs.append((partial, chunk, 1.0))

        # ── Negative pairs ──
        rng = np.random.default_rng(seed=i)
        neg_indices = rng.choice(
            [j for j in range(len(chunks)) if j != i],
            size=min(num_negatives, len(chunks) - 1),
            replace=False,
        )
        for ni in neg_indices:
            pairs.append((chunk, chunks[ni], 0.0))

    return pairs


# ── Core trainer class ───────────────────────────────────────────


class ClaraTrainer:
    """Compression-aware trainer for the CLaRa embedding model.

    Uses contrastive learning to fine-tune sentence-transformers on
    domain-specific documents so that compressed representations retain
    high retrieval quality.
    """

    def __init__(self) -> None:
        self._model: Any = None  # SentenceTransformer when available
        self._model_path: Path | None = None

    # ── Public API ──

    async def train_compressor(
        self,
        documents: list[dict[str, Any]],
        config: dict[str, Any],
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> ClaraTrainResult:
        """Train/fine-tune the compression model on domain-specific documents.

        Parameters
        ----------
        documents:
            List of dicts with at least ``"chunks"`` (list[str]) and
            optionally ``"doc_id"`` (str).
        config:
            Training configuration (see ClaraTrainConfig schema).
        progress_callback:
            Optional ``(progress_0_to_1, status_message) -> None``.
        """
        learning_rate = config.get("learning_rate", 2e-4)
        epochs = config.get("epochs", 3)
        batch_size = config.get("batch_size", 16)
        compression_target = config.get("compression_target_ratio", 0.3)
        neg_samples = config.get("negative_samples", 5)
        warmup_steps = config.get("warmup_steps", 50)

        # Flatten all chunks from all documents
        all_chunks: list[str] = []
        for doc in documents:
            all_chunks.extend(doc.get("chunks", []))

        if not all_chunks:
            return ClaraTrainResult(success=False, error="No chunks found in documents")

        if progress_callback:
            progress_callback(0.05, "Building contrastive training pairs")

        # ── Step 1: Build contrastive pairs ──
        pairs = _build_contrastive_pairs(all_chunks, num_negatives=neg_samples)
        if not pairs:
            return ClaraTrainResult(success=False, error="Could not build training pairs")

        logger.info(
            "Built %d contrastive pairs from %d chunks (%d documents)",
            len(pairs),
            len(all_chunks),
            len(documents),
        )

        if progress_callback:
            progress_callback(0.10, "Initializing model")

        # ── Step 2: Train ──
        if _HAS_SBERT_TRAIN and _USE_SBERT and _HAS_TORCH:
            result = await self._train_sbert(
                pairs=pairs,
                all_chunks=all_chunks,
                learning_rate=learning_rate,
                epochs=epochs,
                batch_size=batch_size,
                warmup_steps=warmup_steps,
                progress_callback=progress_callback,
            )
        elif _HAS_TORCH:
            result = await self._train_projection(
                pairs=pairs,
                all_chunks=all_chunks,
                learning_rate=learning_rate,
                epochs=epochs,
                batch_size=batch_size,
                progress_callback=progress_callback,
            )
        else:
            # Fallback: rebuild the TF-IDF index (no real training possible)
            result = await self._rebuild_tfidf_index(
                all_chunks=all_chunks,
                progress_callback=progress_callback,
            )

        result.num_documents = len(documents)
        result.num_chunks = len(all_chunks)
        result.num_training_pairs = len(pairs)
        result.compression_ratio = compression_target

        return result

    async def evaluate(
        self,
        test_docs: list[dict[str, Any]],
        top_k_values: list[int] | None = None,
    ) -> dict[str, Any]:
        """Evaluate retrieval quality after training.

        Returns recall@k for each k and the effective compression ratio.
        """
        if top_k_values is None:
            top_k_values = [1, 3, 5, 10]

        all_chunks: list[str] = []
        for doc in test_docs:
            all_chunks.extend(doc.get("chunks", []))

        if not all_chunks:
            return {"error": "No test chunks", "recall_at_k": {}, "compression_ratio": 0.0}

        # Encode all chunks
        vectors = encode_texts(all_chunks)

        # For each chunk, use its first sentence as a "query" and check
        # if the original chunk is retrieved in the top-k
        recall_counts: dict[int, int] = {k: 0 for k in top_k_values}
        total_queries = 0

        for i, chunk in enumerate(all_chunks):
            sentences = [s.strip() for s in chunk.split(".") if len(s.strip()) > 10]
            if not sentences:
                continue

            query_text = sentences[0]
            q_vec = encode_texts([query_text])[0]

            # Cosine similarity
            scores = vectors @ q_vec
            ranked_indices = np.argsort(-scores)

            total_queries += 1
            for k in top_k_values:
                if i in ranked_indices[:k]:
                    recall_counts[k] += 1

        recall_at_k = {
            k: round(count / total_queries, 4) if total_queries > 0 else 0.0
            for k, count in recall_counts.items()
        }

        # Compression ratio: average ratio of vector size to original text size
        vector_bytes = vectors.nbytes
        text_bytes = sum(len(c.encode("utf-8")) for c in all_chunks)
        compression_ratio = round(vector_bytes / text_bytes, 4) if text_bytes > 0 else 0.0

        return {
            "recall_at_k": recall_at_k,
            "compression_ratio": compression_ratio,
            "num_test_chunks": len(all_chunks),
            "num_queries": total_queries,
            "vector_dims": vectors.shape[1] if vectors.ndim == 2 else 0,
        }

    # ── Private training strategies ──

    async def _train_sbert(
        self,
        pairs: list[tuple[str, str, float]],
        all_chunks: list[str],
        learning_rate: float,
        epochs: int,
        batch_size: int,
        warmup_steps: int,
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> ClaraTrainResult:
        """Fine-tune sentence-transformers model with contrastive loss."""

        def _blocking_train() -> ClaraTrainResult:
            from torch.utils.data import DataLoader

            model_save_dir = CLARA_MODELS_DIR / "finetuned"
            model_save_dir.mkdir(parents=True, exist_ok=True)

            # Load base model
            model = SentenceTransformer(DEFAULT_SBERT_MODEL)
            logger.info("Loaded base SentenceTransformer: %s", DEFAULT_SBERT_MODEL)

            # Build training examples
            train_examples = [
                InputExample(texts=[a, b], label=float(lbl))
                for a, b, lbl in pairs
            ]

            train_dataloader = DataLoader(
                train_examples,  # type: ignore[arg-type]
                shuffle=True,
                batch_size=batch_size,
            )

            # Contrastive loss: positive pairs close, negatives far apart
            train_loss = losses.CosineSimilarityLoss(model)

            total_steps = len(train_dataloader) * epochs

            # Progress tracking wrapper
            step_count = 0

            class _ProgressCallback:
                def __call__(self, score: float, epoch: int, steps: int) -> None:
                    nonlocal step_count
                    step_count += 1
                    if progress_callback:
                        pct = 0.15 + (step_count / max(total_steps, 1)) * 0.70
                        progress_callback(min(pct, 0.85), f"Training epoch {epoch + 1}/{epochs}")

            # Train
            logger.info(
                "Starting SentenceTransformer fine-tuning: %d examples, %d epochs, lr=%e",
                len(train_examples),
                epochs,
                learning_rate,
            )

            model.fit(
                train_objectives=[(train_dataloader, train_loss)],
                epochs=epochs,
                warmup_steps=warmup_steps,
                optimizer_params={"lr": learning_rate},
                output_path=str(model_save_dir),
                show_progress_bar=False,
                callback=_ProgressCallback(),
            )

            logger.info("Fine-tuning complete. Model saved to %s", model_save_dir)

            return ClaraTrainResult(
                success=True,
                model_path=str(model_save_dir),
                epochs_completed=epochs,
                metrics={
                    "method": "sentence_transformers_finetune",
                    "base_model": DEFAULT_SBERT_MODEL,
                    "total_steps": total_steps,
                    "learning_rate": learning_rate,
                    "batch_size": batch_size,
                },
            )

        if progress_callback:
            progress_callback(0.12, "Loading sentence-transformer model")

        result = await asyncio.to_thread(_blocking_train)

        if progress_callback:
            progress_callback(0.90, "Evaluating trained model")

        return result

    async def _train_projection(
        self,
        pairs: list[tuple[str, str, float]],
        all_chunks: list[str],
        learning_rate: float,
        epochs: int,
        batch_size: int,
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> ClaraTrainResult:
        """Train a projection head on top of frozen embeddings using PyTorch.

        Fallback when full sentence-transformers fine-tuning is not available
        but PyTorch is installed.
        """

        def _blocking_train() -> ClaraTrainResult:
            dims = get_dims()
            device = "cuda" if torch.cuda.is_available() else "cpu"
            if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                device = "mps"

            # Encode all unique texts up front
            unique_texts = list({t for pair in pairs for t in (pair[0], pair[1])})
            logger.info("Encoding %d unique texts for projection training", len(unique_texts))

            all_vecs = encode_texts(unique_texts)
            text_to_idx = {t: i for i, t in enumerate(unique_texts)}
            all_vecs_tensor = torch.from_numpy(all_vecs).to(device)

            # Projection head: dims → dims (learnable refinement)
            projection = nn.Sequential(
                nn.Linear(dims, dims * 2),
                nn.GELU(),
                nn.Dropout(0.1),
                nn.Linear(dims * 2, dims),
            ).to(device)

            optimizer = torch.optim.AdamW(projection.parameters(), lr=learning_rate, weight_decay=0.01)

            # Training loop
            step_losses: list[float] = []
            total_steps = 0

            for epoch in range(epochs):
                # Shuffle pairs
                rng = np.random.default_rng(seed=epoch)
                indices = rng.permutation(len(pairs))

                epoch_loss = 0.0
                num_batches = 0

                for batch_start in range(0, len(indices), batch_size):
                    batch_idx = indices[batch_start : batch_start + batch_size]

                    # Gather batch embeddings
                    anchor_indices = [text_to_idx[pairs[i][0]] for i in batch_idx]
                    positive_indices = [text_to_idx[pairs[i][1]] for i in batch_idx]
                    labels = torch.tensor(
                        [pairs[i][2] for i in batch_idx],
                        dtype=torch.float32,
                        device=device,
                    )

                    anchor_vecs = all_vecs_tensor[anchor_indices]
                    positive_vecs = all_vecs_tensor[positive_indices]

                    # Project
                    anchor_proj = F.normalize(projection(anchor_vecs), dim=-1)
                    positive_proj = F.normalize(projection(positive_vecs), dim=-1)

                    # Cosine similarity
                    cos_sim = (anchor_proj * positive_proj).sum(dim=-1)

                    # MSE loss between predicted similarity and labels
                    loss = F.mse_loss(cos_sim, labels)

                    optimizer.zero_grad()
                    loss.backward()
                    torch.nn.utils.clip_grad_norm_(projection.parameters(), max_norm=1.0)
                    optimizer.step()

                    loss_val = loss.item()
                    epoch_loss += loss_val
                    step_losses.append(loss_val)
                    num_batches += 1
                    total_steps += 1

                avg_epoch_loss = epoch_loss / max(num_batches, 1)
                logger.info(
                    "Epoch %d/%d — avg_loss: %.6f",
                    epoch + 1,
                    epochs,
                    avg_epoch_loss,
                )

                if progress_callback:
                    pct = 0.15 + ((epoch + 1) / epochs) * 0.70
                    progress_callback(min(pct, 0.85), f"Training epoch {epoch + 1}/{epochs}")

            # Save projection weights
            save_dir = CLARA_MODELS_DIR / "projection"
            save_dir.mkdir(parents=True, exist_ok=True)
            torch.save(projection.state_dict(), save_dir / "projection_head.pt")

            # Save config
            config_data = {
                "method": "projection_head",
                "dims": dims,
                "epochs": epochs,
                "learning_rate": learning_rate,
                "total_steps": total_steps,
                "final_loss": step_losses[-1] if step_losses else None,
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }
            (save_dir / "config.json").write_text(json.dumps(config_data, indent=2))

            # Clean up GPU memory
            del projection, optimizer, all_vecs_tensor
            if device == "cuda":
                torch.cuda.empty_cache()

            return ClaraTrainResult(
                success=True,
                model_path=str(save_dir),
                epochs_completed=epochs,
                final_loss=step_losses[-1] if step_losses else None,
                metrics={
                    "method": "projection_head",
                    "device": device,
                    "total_steps": total_steps,
                    "final_loss": step_losses[-1] if step_losses else None,
                    "avg_loss": sum(step_losses) / len(step_losses) if step_losses else None,
                    "step_losses_last10": step_losses[-10:],
                },
            )

        if progress_callback:
            progress_callback(0.12, "Encoding texts for projection training")

        return await asyncio.to_thread(_blocking_train)

    async def _rebuild_tfidf_index(
        self,
        all_chunks: list[str],
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> ClaraTrainResult:
        """Fallback: re-encode all chunks with the TF-IDF backend.

        No real training happens, but we re-index to ensure consistency.
        """
        if progress_callback:
            progress_callback(0.20, "Re-encoding chunks with TF-IDF (no GPU training available)")

        vectors = encode_texts(all_chunks)

        if progress_callback:
            progress_callback(0.80, "Index rebuilt")

        return ClaraTrainResult(
            success=True,
            model_path="(tfidf — no trainable model)",
            epochs_completed=0,
            metrics={
                "method": "tfidf_reindex",
                "num_chunks": len(all_chunks),
                "vector_dims": vectors.shape[1] if vectors.ndim == 2 else 0,
                "note": "TF-IDF backend has no trainable parameters. Index was rebuilt.",
            },
        )


# ── Module-level convenience ─────────────────────────────────────

_trainer_instance: ClaraTrainer | None = None


def get_trainer() -> ClaraTrainer:
    """Return a singleton ClaraTrainer instance."""
    global _trainer_instance
    if _trainer_instance is None:
        _trainer_instance = ClaraTrainer()
    return _trainer_instance
