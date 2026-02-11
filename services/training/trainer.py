"""LoRA adapter trainer — orchestrates real LoRA training with fallback.

Gathers training data from CLaRa document chunks or user-provided extracts,
then delegates to `lora_trainer.train_adapter()` for real LoRA fine-tuning
via PEFT.  Falls back gracefully to a prompt-injection adapter when LoRA
training is not possible (missing dependencies, incompatible model, OOM).
"""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime
from pathlib import Path

from common.config import ADAPTERS_DIR
from common.database import Database
from training.lora_trainer import train_adapter, TrainingResult
from training.tokenizer_utils import count_tokens

logger = logging.getLogger("training.trainer")


async def run_training(
    run_id: str,
    adapter_id: str,
    base_model_id: str,
    source_type: str,
    source_ref: str | None,
    extract_content: str | None,
    goal: str | None = None,
    document_ids: list[str] | None = None,
    collection_ids: list[str] | None = None,
) -> None:
    """Execute a training run (background task).

    1. Gather training data from CLaRa collection or pasted extract.
    2. Delegate to ``train_adapter()`` for real LoRA training.
    3. Update DB with progress, metrics, and final status.
    """
    db = await Database.instance()

    try:
        # ── Update status: preparing ────────────────────────────────────
        await db.execute(
            "UPDATE training_runs SET status = 'preparing', progress_percent = 5.0 WHERE id = ?",
            (run_id,),
        )
        await db.commit()

        # ── Step 1: Gather training data ────────────────────────────────
        training_text = ""

        # Prefer extract_content when available — it contains the user-curated
        # extracts from the Knowledge Pack step. Fall back to collection chunks
        # or document content from the DB.
        if extract_content:
            training_text = extract_content
            logger.info("Using curated extract content (%d chars)", len(training_text))

        elif source_type == "collection" and source_ref:
            rows = await db.fetchall(
                """
                SELECT dc.text FROM doc_chunks dc
                JOIN collection_documents cd ON cd.document_id = dc.document_id
                WHERE cd.collection_id = ?
                ORDER BY dc.document_id, dc.chunk_index
                """,
                (source_ref,),
            )
            training_text = "\n\n".join(row["text"] for row in rows if row["text"])
            logger.info("Collected %d chunks from collection %s", len(rows), source_ref)

        elif source_type == "collection" and collection_ids:
            # Multiple collections selected — gather from all of them
            all_chunks = []
            for cid in collection_ids:
                rows = await db.fetchall(
                    """
                    SELECT dc.text FROM doc_chunks dc
                    JOIN collection_documents cd ON cd.document_id = dc.document_id
                    WHERE cd.collection_id = ?
                    ORDER BY dc.document_id, dc.chunk_index
                    """,
                    (cid,),
                )
                all_chunks.extend(row["text"] for row in rows if row["text"])
            training_text = "\n\n".join(all_chunks)
            logger.info("Collected %d chunks from %d collections", len(all_chunks), len(collection_ids))

        elif document_ids:
            # Direct document selection — gather content from document_content table
            parts = []
            for doc_id in document_ids:
                row = await db.fetchone(
                    "SELECT content FROM document_content WHERE document_id = ?",
                    (doc_id,),
                )
                if row and row["content"]:
                    parts.append(row["content"])
            training_text = "\n\n".join(parts)
            logger.info("Collected content from %d documents", len(parts))

        if not training_text.strip():
            await db.execute(
                "UPDATE training_runs SET status = 'failed', error_message = 'No training data found.', completed_at = ? WHERE id = ?",
                (datetime.utcnow().isoformat(), run_id),
            )
            await db.commit()
            return

        token_count = count_tokens(training_text)
        logger.info("Training data: %d chars, ~%d tokens", len(training_text), token_count)

        # ── Update status: training ─────────────────────────────────────
        await db.execute(
            "UPDATE training_runs SET status = 'training', progress_percent = 10.0, eta_seconds = 120 WHERE id = ?",
            (run_id,),
        )
        await db.commit()

        # ── Step 2: Create a progress callback ──────────────────────────
        async def _update_progress(progress_pct: float, eta: int) -> None:
            """Update training progress in the database."""
            try:
                await db.execute(
                    "UPDATE training_runs SET progress_percent = ?, eta_seconds = ? WHERE id = ?",
                    (progress_pct, eta, run_id),
                )
                await db.commit()
            except Exception:
                pass  # Don't let DB errors interrupt training

        # Capture the running loop *before* we enter a worker thread so the
        # synchronous progress callback can safely schedule DB updates back
        # on the main event loop via run_coroutine_threadsafe().
        _running_loop = asyncio.get_running_loop()

        def _sync_progress_callback(progress_pct: float, eta: int) -> None:
            """Synchronous wrapper that schedules the async DB update (thread-safe)."""
            try:
                asyncio.run_coroutine_threadsafe(_update_progress(progress_pct, eta), _running_loop)
            except RuntimeError:
                pass  # Event loop closed — skip this progress update

        # ── Step 3: Run real training ───────────────────────────────────
        adapter_dir = ADAPTERS_DIR / adapter_id

        result: TrainingResult = await train_adapter(
            adapter_dir=adapter_dir,
            base_model_id=base_model_id,
            training_text=training_text,
            source_type=source_type,
            max_steps=50,
            learning_rate=2e-4,
            lora_rank=8,
            lora_alpha=16,
            lora_dropout=0.05,
            max_seq_length=512,
            progress_callback=_sync_progress_callback,
        )

        # ── Step 4: Finalize ────────────────────────────────────────────
        if not result.success:
            await db.execute(
                "UPDATE training_runs SET status = 'failed', error_message = ?, completed_at = ? WHERE id = ?",
                (result.error or "Training produced no output.", datetime.utcnow().isoformat(), run_id),
            )
            await db.commit()
            return

        # Calculate disk usage
        disk_bytes = 0
        if adapter_dir.exists():
            disk_bytes = sum(f.stat().st_size for f in adapter_dir.rglob("*") if f.is_file())

        # Update adapter with disk size
        await db.execute(
            "UPDATE adapters SET disk_bytes = ? WHERE id = ?",
            (disk_bytes, adapter_id),
        )

        # Build metrics JSON
        metrics = {
            "format": result.format,
            "num_samples": result.num_samples,
            "num_steps": result.num_steps,
            "data_chars": len(training_text),
            "data_tokens": token_count,
        }
        if goal:
            metrics["goal"] = goal
        if result.final_loss is not None:
            metrics["final_loss"] = round(result.final_loss, 6)
        if result.metrics:
            metrics.update({
                k: v for k, v in result.metrics.items()
                if k not in ("step_losses",)  # Skip large arrays
            })
        if result.error:
            metrics["fallback_note"] = result.error

        # Mark training complete
        await db.execute(
            "UPDATE training_runs SET status = 'completed', progress_percent = 100.0, eta_seconds = 0, completed_at = ?, metrics_json = ? WHERE id = ?",
            (datetime.utcnow().isoformat(), json.dumps(metrics), run_id),
        )
        await db.commit()

        logger.info(
            "Training complete for adapter %s: format=%s, samples=%d, steps=%d",
            adapter_id,
            result.format,
            result.num_samples,
            result.num_steps,
        )

    except Exception as e:
        logger.exception("Training failed for run %s", run_id)
        try:
            await db.execute(
                "UPDATE training_runs SET status = 'failed', error_message = ?, completed_at = ? WHERE id = ?",
                (str(e), datetime.utcnow().isoformat(), run_id),
            )
            await db.commit()
        except Exception:
            pass
