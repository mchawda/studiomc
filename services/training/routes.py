# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Training API routes.

Endpoints:
  POST /training/create                    — Create adapter + start training (with configurable hyperparams)
  GET  /training/adapters                 — List all adapters
  GET  /training/adapters/{adapter_id}     — Get single adapter
  GET  /training/runs/{run_id}/status      — Get training run progress
  POST /training/adapters/{adapter_id}/activate — Set adapter as active
  DELETE /training/adapters/{adapter_id}  — Delete adapter and its files
  GET  /training/prompts                  — Return suggested extract prompts
  GET  /training/runs                     — List all training runs with history
  POST /training/runs/{run_id}/rerun      — Re-run a completed training with same or different params
  POST /training/export/merge             — Merge adapter into base model
  POST /training/export/gguf             — Export merged model to GGUF
  POST /training/export/safetensors      — Export merged model to safetensors
  POST /training/export/huggingface      — Push model to HuggingFace Hub
  POST /training/distill                  — Start knowledge distillation job
  GET  /training/distill/{run_id}/status  — Check distillation status
  POST /training/context-distill          — Start context distillation
  GET  /training/context-distill/{run_id}/status — Check context distillation status
  GET  /health                            — Health check
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
import uuid
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from common.config import ADAPTERS_DIR
from common.database import Database
from common.schemas import (
    Adapter,
    ContextDistillRequest,
    ContextDistillStatus,
    DistillRequest,
    DistillStatus,
    SuggestedExtractPrompt,
    TrainingCreateRequest,
    TrainingRun,
    TrainingRunStatus,
    TrainingSourceType,
)

from training.trainer import run_training

logger = logging.getLogger("training.routes")

router = APIRouter(prefix="/training")

# ── In-memory job trackers for distillation ──────────────────────

_distill_jobs: dict[str, DistillStatus] = {}
_context_distill_jobs: dict[str, ContextDistillStatus] = {}


# ── Health check ─────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "training"}


# ── Training creation ────────────────────────────────────────────


@router.post("/create")
async def create_training(req: TrainingCreateRequest) -> dict[str, str]:
    """Create adapter + start training."""
    db = await Database.instance()

    # Generate IDs
    adapter_id = f"adapter-{uuid.uuid4().hex[:8]}"
    run_id = f"run-{uuid.uuid4().hex[:8]}"

    try:
        # Insert adapter row
        await db.execute(
            """
            INSERT INTO adapters (id, name, base_model_id, source_type, source_ref, is_active)
            VALUES (?, ?, ?, ?, ?, 0)
            """,
            (adapter_id, req.adapter_name, req.base_model_id, req.source_type.value, req.source_ref),
        )

        # Insert training_run row
        await db.execute(
            """
            INSERT INTO training_runs (id, adapter_id, status, progress_percent, started_at)
            VALUES (?, ?, ?, 0.0, ?)
            """,
            (run_id, adapter_id, TrainingRunStatus.pending.value, datetime.utcnow().isoformat()),
        )

        await db.commit()

        # Launch background training task
        asyncio.create_task(
            run_training(
                run_id=run_id,
                adapter_id=adapter_id,
                base_model_id=req.base_model_id,
                source_type=req.source_type.value,
                source_ref=req.source_ref,
                extract_content=req.extract_content,
                goal=req.goal,
                document_ids=req.document_ids,
                collection_ids=req.collection_ids,
            )
        )

        logger.info("Created training run %s for adapter %s", run_id, adapter_id)
        return {"run_id": run_id, "adapter_id": adapter_id, "status": "pending"}

    except Exception as e:
        logger.exception("Failed to create training")
        raise HTTPException(status_code=500, detail=str(e))


# ── Adapters ─────────────────────────────────────────────────────


@router.get("/adapters", response_model=list[Adapter])
async def list_adapters() -> list[Adapter]:
    """List all adapters."""
    db = await Database.instance()
    rows = await db.fetchall(
        """
        SELECT id, name, base_model_id, source_type, source_ref, disk_bytes,
               created_at, last_used_at, is_active
        FROM adapters
        ORDER BY created_at DESC
        """
    )

    return [
        Adapter(
            id=row["id"],
            name=row["name"],
            base_model_id=row["base_model_id"],
            source_type=TrainingSourceType(row["source_type"]),
            source_ref=row["source_ref"],
            disk_bytes=row["disk_bytes"] or 0,
            created_at=datetime.fromisoformat(row["created_at"]),
            last_used_at=datetime.fromisoformat(row["last_used_at"]) if row["last_used_at"] else None,
            is_active=bool(row["is_active"]),
        )
        for row in rows
    ]


@router.get("/adapters/{adapter_id}", response_model=Adapter)
async def get_adapter(adapter_id: str) -> Adapter:
    """Get single adapter."""
    db = await Database.instance()
    row = await db.fetchone(
        """
        SELECT id, name, base_model_id, source_type, source_ref, disk_bytes,
               created_at, last_used_at, is_active
        FROM adapters
        WHERE id = ?
        """,
        (adapter_id,),
    )

    if not row:
        raise HTTPException(status_code=404, detail=f"Adapter {adapter_id} not found")

    return Adapter(
        id=row["id"],
        name=row["name"],
        base_model_id=row["base_model_id"],
        source_type=TrainingSourceType(row["source_type"]),
        source_ref=row["source_ref"],
        disk_bytes=row["disk_bytes"] or 0,
        created_at=datetime.fromisoformat(row["created_at"]),
        last_used_at=datetime.fromisoformat(row["last_used_at"]) if row["last_used_at"] else None,
        is_active=bool(row["is_active"]),
    )


@router.post("/adapters/{adapter_id}/activate")
async def activate_adapter(adapter_id: str) -> dict[str, str]:
    """Set adapter as active (deactivate others for same base_model_id)."""
    db = await Database.instance()

    # Get adapter's base_model_id
    adapter_row = await db.fetchone("SELECT base_model_id FROM adapters WHERE id = ?", (adapter_id,))
    if not adapter_row:
        raise HTTPException(status_code=404, detail=f"Adapter {adapter_id} not found")

    base_model_id = adapter_row["base_model_id"]

    try:
        # Deactivate all adapters for this base model
        await db.execute(
            "UPDATE adapters SET is_active = 0 WHERE base_model_id = ?",
            (base_model_id,),
        )

        # Activate this adapter
        await db.execute(
            "UPDATE adapters SET is_active = 1 WHERE id = ?",
            (adapter_id,),
        )

        await db.commit()
        logger.info("Activated adapter %s for base_model %s", adapter_id, base_model_id)
        return {"status": "ok", "adapter_id": adapter_id}

    except Exception as e:
        logger.exception("Failed to activate adapter")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/adapters/{adapter_id}")
async def delete_adapter(adapter_id: str) -> dict[str, str]:
    """Delete adapter and its files."""
    db = await Database.instance()

    # Check if adapter exists
    adapter_row = await db.fetchone("SELECT id FROM adapters WHERE id = ?", (adapter_id,))
    if not adapter_row:
        raise HTTPException(status_code=404, detail=f"Adapter {adapter_id} not found")

    try:
        # Delete adapter directory
        adapter_dir = ADAPTERS_DIR / adapter_id
        if adapter_dir.exists():
            shutil.rmtree(adapter_dir)
            logger.info("Deleted adapter directory: %s", adapter_dir)

        # Delete adapter row (training_runs will be cascade-deleted or set to NULL)
        await db.execute("DELETE FROM adapters WHERE id = ?", (adapter_id,))
        await db.commit()

        logger.info("Deleted adapter %s", adapter_id)
        return {"status": "ok", "adapter_id": adapter_id}

    except Exception as e:
        logger.exception("Failed to delete adapter")
        raise HTTPException(status_code=500, detail=str(e))


# ── Training runs ─────────────────────────────────────────────────


@router.get("/runs/{run_id}/status", response_model=TrainingRun)
async def get_training_status(run_id: str) -> TrainingRun:
    """Get training run progress."""
    db = await Database.instance()
    row = await db.fetchone(
        """
        SELECT id, adapter_id, status, progress_percent, eta_seconds,
               error_message, metrics_json, started_at, completed_at
        FROM training_runs
        WHERE id = ?
        """,
        (run_id,),
    )

    if not row:
        raise HTTPException(status_code=404, detail=f"Training run {run_id} not found")

    return TrainingRun(
        id=row["id"],
        adapter_id=row["adapter_id"],
        status=TrainingRunStatus(row["status"]),
        progress_percent=row["progress_percent"] or 0.0,
        eta_seconds=row["eta_seconds"],
        error_message=row["error_message"],
        metrics_json=row["metrics_json"],
        started_at=datetime.fromisoformat(row["started_at"]),
        completed_at=datetime.fromisoformat(row["completed_at"]) if row["completed_at"] else None,
    )


# ── Extract prompts ──────────────────────────────────────────────


@router.get("/prompts", response_model=list[SuggestedExtractPrompt])
async def get_prompts() -> list[SuggestedExtractPrompt]:
    """Return the list of suggested extract prompts."""
    return [
        SuggestedExtractPrompt(
            id="qa_pairs",
            label="Q&A Pairs",
            prompt="Extract question-answer pairs from this document. Format each as:\nQ: [question]\nA: [answer]",
        ),
        SuggestedExtractPrompt(
            id="key_facts",
            label="Key Facts",
            prompt="Extract key facts and important information from this document. List each fact as a bullet point.",
        ),
        SuggestedExtractPrompt(
            id="section_summaries",
            label="Section Summaries",
            prompt="Summarize each major section or chapter of this document. Include the section title and a concise summary.",
        ),
        SuggestedExtractPrompt(
            id="terms_definitions",
            label="Terms & Definitions",
            prompt="Extract important terms and their definitions from this document. Format as:\nTerm: [term]\nDefinition: [definition]",
        ),
    ]


# ── Knowledge Distillation ───────────────────────────────────────


@router.post("/distill", response_model=DistillStatus)
async def start_distillation(req: DistillRequest) -> DistillStatus:
    """Start a knowledge distillation job (teacher → student)."""
    if req.use_cloud_teacher and not req.cloud_consent:
        raise HTTPException(
            status_code=400,
            detail="Cloud teacher requires explicit consent. Set cloud_consent=True.",
        )

    run_id = f"distill-{uuid.uuid4().hex[:8]}"
    status = DistillStatus(
        run_id=run_id,
        status="pending",
        progress=0.0,
        total_epochs=req.config.epochs,
    )
    _distill_jobs[run_id] = status

    asyncio.create_task(
        _run_distillation(
            run_id=run_id,
            teacher_model_id=req.teacher_model_id,
            student_model_id=req.student_model_id,
            dataset_collection_id=req.dataset_collection_id,
            dataset_text=req.dataset_text,
            config=req.config.model_dump(),
            use_cloud=req.use_cloud_teacher,
        )
    )

    logger.info("Created distillation run %s: teacher=%s → student=%s", run_id, req.teacher_model_id, req.student_model_id)
    return status


@router.get("/distill/{run_id}/status", response_model=DistillStatus)
async def distill_status(run_id: str) -> DistillStatus:
    """Check status of a knowledge distillation run."""
    status = _distill_jobs.get(run_id)
    if status is None:
        raise HTTPException(status_code=404, detail=f"Distillation run {run_id} not found")
    return status


async def _run_distillation(
    run_id: str,
    teacher_model_id: str,
    student_model_id: str,
    dataset_collection_id: str | None,
    dataset_text: str | None,
    config: dict,
    use_cloud: bool,
) -> None:
    """Background task: run knowledge distillation."""
    from training.distiller import get_distiller

    status = _distill_jobs[run_id]
    status.status = "preparing"

    try:
        # Gather dataset
        dataset: list[str] = []

        if dataset_text:
            # Split provided text into training samples
            paragraphs = [p.strip() for p in dataset_text.split("\n\n") if p.strip()]
            dataset = paragraphs
            logger.info("Using %d text paragraphs for distillation", len(dataset))

        elif dataset_collection_id:
            db = await Database.instance()
            rows = await db.fetchall(
                """
                SELECT dc.text FROM doc_chunks dc
                JOIN collection_documents cd ON cd.document_id = dc.document_id
                WHERE cd.collection_id = ?
                ORDER BY dc.document_id, dc.chunk_index
                """,
                (dataset_collection_id,),
            )
            dataset = [r["text"] for r in rows if r["text"]]
            logger.info("Collected %d chunks from collection %s", len(dataset), dataset_collection_id)

        if not dataset:
            status.status = "error"
            status.error = "No training data found"
            return

        config["use_cloud_teacher"] = use_cloud

        def _progress(pct: float, msg: str) -> None:
            status.progress = pct
            if pct < 0.10:
                status.status = "preparing"
            elif pct < 0.45:
                status.status = "generating_soft_labels"
            elif pct < 0.85:
                status.status = "training"
            else:
                status.status = "evaluating"

        distiller = get_distiller()
        result = await distiller.distill(
            teacher_model_id=teacher_model_id,
            student_model_id=student_model_id,
            dataset=dataset,
            config=config,
            progress_callback=_progress,
        )

        if not result.success:
            status.status = "error"
            status.error = result.error
            return

        status.status = "complete"
        status.progress = 1.0
        status.current_epoch = result.epochs_completed
        status.metrics = {
            **result.metrics,
            "num_samples": result.num_samples,
            "adapter_dir": result.adapter_dir,
        }
        if result.final_loss is not None:
            status.metrics["final_loss"] = result.final_loss

        logger.info("Distillation run=%s complete: %d samples, %d epochs", run_id, result.num_samples, result.epochs_completed)

    except Exception as exc:
        logger.exception("Distillation run=%s failed", run_id)
        status.status = "error"
        status.error = str(exc)


# ── Context Distillation ─────────────────────────────────────────


@router.post("/context-distill", response_model=ContextDistillStatus)
async def start_context_distillation(req: ContextDistillRequest) -> ContextDistillStatus:
    """Start a context distillation run."""
    run_id = f"ctx-distill-{uuid.uuid4().hex[:8]}"
    status = ContextDistillStatus(
        run_id=run_id,
        status="pending",
        progress=0.0,
        current_phase="initializing",
    )
    _context_distill_jobs[run_id] = status

    asyncio.create_task(
        _run_context_distillation(
            run_id=run_id,
            model_id=req.model_id,
            collection_id=req.collection_id,
            config=req.config.model_dump(),
        )
    )

    logger.info("Created context distillation run %s: model=%s, collection=%s", run_id, req.model_id, req.collection_id)
    return status


@router.get("/context-distill/{run_id}/status", response_model=ContextDistillStatus)
async def context_distill_status(run_id: str) -> ContextDistillStatus:
    """Check status of a context distillation run."""
    status = _context_distill_jobs.get(run_id)
    if status is None:
        raise HTTPException(status_code=404, detail=f"Context distillation run {run_id} not found")
    return status


async def _run_context_distillation(
    run_id: str,
    model_id: str,
    collection_id: str,
    config: dict,
) -> None:
    """Background task: run context distillation."""
    from training.context_distiller import get_context_distiller

    status = _context_distill_jobs[run_id]
    status.status = "preparing"
    status.current_phase = "Gathering documents"

    try:
        db = await Database.instance()

        # Gather full document texts from the collection
        rows = await db.fetchall(
            """
            SELECT dc.document_id, dc.text, dc.chunk_index
            FROM doc_chunks dc
            JOIN collection_documents cd ON cd.document_id = dc.document_id
            WHERE cd.collection_id = ?
            ORDER BY dc.document_id, dc.chunk_index
            """,
            (collection_id,),
        )

        if not rows:
            status.status = "error"
            status.error = f"No documents found in collection '{collection_id}'"
            return

        # Reconstruct document texts from chunks
        doc_texts: dict[str, list[str]] = {}
        for r in rows:
            doc_id = r["document_id"]
            if doc_id not in doc_texts:
                doc_texts[doc_id] = []
            doc_texts[doc_id].append(r["text"])

        documents = [
            {"doc_id": doc_id, "text": "\n\n".join(chunks)}
            for doc_id, chunks in doc_texts.items()
        ]

        logger.info("Collected %d documents from collection %s", len(documents), collection_id)

        def _progress(pct: float, msg: str) -> None:
            status.progress = pct
            status.current_phase = msg
            if pct < 0.10:
                status.status = "preparing"
            elif pct < 0.40:
                status.status = "generating_qa"
            elif pct < 0.50:
                status.status = "compressing"
            elif pct < 0.85:
                status.status = "training"
            else:
                status.status = "evaluating"

        distiller = get_context_distiller()
        result = await distiller.distill_context(
            model_id=model_id,
            documents=documents,
            config=config,
            progress_callback=_progress,
        )

        if not result.success:
            status.status = "error"
            status.error = result.error
            return

        status.status = "complete"
        status.progress = 1.0
        status.current_phase = "Complete"
        status.metrics = {
            **result.metrics,
            "num_documents": result.num_documents,
            "num_qa_pairs": result.num_qa_pairs,
            "adapter_dir": result.adapter_dir,
        }
        if result.final_loss is not None:
            status.metrics["final_loss"] = result.final_loss

        logger.info(
            "Context distillation run=%s complete: %d docs, %d qa pairs",
            run_id,
            result.num_documents,
            result.num_qa_pairs,
        )

    except Exception as exc:
        logger.exception("Context distillation run=%s failed", run_id)
        status.status = "error"
        status.error = str(exc)


# ── Training History ──────────────────────────────────────────────


@router.get("/runs")
async def list_training_runs() -> list[dict]:
    """List all training runs with their metrics and params."""
    db = await Database.instance()
    rows = await db.fetchall(
        """
        SELECT tr.id, tr.adapter_id, tr.status, tr.progress_percent,
               tr.eta_seconds, tr.error_message, tr.metrics_json,
               tr.started_at, tr.completed_at,
               a.name as adapter_name, a.base_model_id
        FROM training_runs tr
        LEFT JOIN adapters a ON a.id = tr.adapter_id
        ORDER BY tr.started_at DESC
        """
    )
    return [
        {
            "id": r["id"],
            "adapter_id": r["adapter_id"],
            "adapter_name": r["adapter_name"],
            "base_model_id": r["base_model_id"],
            "status": r["status"],
            "progress_percent": r["progress_percent"],
            "metrics": json.loads(r["metrics_json"]) if r["metrics_json"] else None,
            "started_at": r["started_at"],
            "completed_at": r["completed_at"],
            "error_message": r["error_message"],
        }
        for r in rows
    ]


# ── Model Export ──────────────────────────────────────────────────


class ExportMergeRequest(BaseModel):
    adapter_id: str


class ExportGGUFRequest(BaseModel):
    adapter_id: str
    quantization: str = "q4_k_m"


class ExportSafetensorsRequest(BaseModel):
    adapter_id: str


class ExportHuggingFaceRequest(BaseModel):
    adapter_id: str
    repo_id: str
    token: str
    private: bool = True


@router.post("/export/merge")
async def export_merge(req: ExportMergeRequest) -> dict:
    """Merge a LoRA adapter into the base model."""
    from training.export import merge_adapter

    adapter_dir = ADAPTERS_DIR / req.adapter_id
    if not adapter_dir.exists():
        raise HTTPException(status_code=404, detail=f"Adapter {req.adapter_id} not found")

    output_dir = ADAPTERS_DIR / f"{req.adapter_id}-merged"
    result = await merge_adapter(adapter_dir, output_dir)

    if result is None:
        raise HTTPException(status_code=500, detail="Merge failed")

    size = sum(f.stat().st_size for f in output_dir.rglob("*") if f.is_file())
    return {
        "success": True,
        "merged_path": str(output_dir),
        "size_bytes": size,
    }


@router.post("/export/gguf")
async def export_gguf(req: ExportGGUFRequest) -> dict:
    """Export a merged model to GGUF format."""
    from training.export import export_to_gguf, merge_adapter

    merged_dir = ADAPTERS_DIR / f"{req.adapter_id}-merged"
    if not merged_dir.exists():
        adapter_dir = ADAPTERS_DIR / req.adapter_id
        if not adapter_dir.exists():
            raise HTTPException(status_code=404, detail=f"Adapter {req.adapter_id} not found")
        result = await merge_adapter(adapter_dir, merged_dir)
        if result is None:
            raise HTTPException(status_code=500, detail="Merge failed — cannot export")

    output_path = ADAPTERS_DIR / f"{req.adapter_id}.gguf"
    result = await export_to_gguf(merged_dir, output_path, req.quantization)

    return {
        "success": result.success,
        "output_path": result.output_path,
        "size_bytes": result.size_bytes,
        "error": result.error,
    }


@router.post("/export/safetensors")
async def export_safetensors(req: ExportSafetensorsRequest) -> dict:
    """Export a merged model as safetensors."""
    from training.export import export_to_safetensors, merge_adapter

    merged_dir = ADAPTERS_DIR / f"{req.adapter_id}-merged"
    if not merged_dir.exists():
        adapter_dir = ADAPTERS_DIR / req.adapter_id
        if not adapter_dir.exists():
            raise HTTPException(status_code=404, detail=f"Adapter {req.adapter_id} not found")
        result = await merge_adapter(adapter_dir, merged_dir)
        if result is None:
            raise HTTPException(status_code=500, detail="Merge failed — cannot export")

    output_dir = ADAPTERS_DIR / f"{req.adapter_id}-safetensors"
    result = await export_to_safetensors(merged_dir, output_dir)

    return {
        "success": result.success,
        "output_path": result.output_path,
        "size_bytes": result.size_bytes,
        "error": result.error,
    }


@router.post("/export/huggingface")
async def export_huggingface(req: ExportHuggingFaceRequest) -> dict:
    """Push a model to HuggingFace Hub."""
    from training.export import push_to_huggingface, merge_adapter

    merged_dir = ADAPTERS_DIR / f"{req.adapter_id}-merged"
    if not merged_dir.exists():
        adapter_dir = ADAPTERS_DIR / req.adapter_id
        if not adapter_dir.exists():
            raise HTTPException(status_code=404, detail=f"Adapter {req.adapter_id} not found")
        result = await merge_adapter(adapter_dir, merged_dir)
        if result is None:
            raise HTTPException(status_code=500, detail="Merge failed — cannot push")

    result = await push_to_huggingface(
        merged_dir, req.repo_id, req.token, req.private
    )

    return {
        "success": result.success,
        "output_path": result.output_path,
        "error": result.error,
    }
