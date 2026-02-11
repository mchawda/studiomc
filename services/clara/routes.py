"""CLaRa API routes.

Endpoints:
  POST /clara/ingest         — Ingest docs → chunks → latent vectors (background job)
  GET  /clara/ingest/status/{job_id} — Check ingestion progress
  POST /clara/query          — Query → top-k latent vectors + optional snippets
  POST /clara/answer         — Query + vectors → answer + citations + groundedness
  POST /clara/train          — Start compression training on a collection
  GET  /clara/train/{run_id}/status — Check training status
  GET  /health               — Health check
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import time
import uuid
from typing import Any

import numpy as np
from fastapi import APIRouter, BackgroundTasks, HTTPException

from common.config import INDEXES_DIR
from common.database import Database
from common.schemas import (
    ClaraAnswerRequest,
    ClaraAnswerResponse,
    ClaraIngestRequest,
    ClaraIngestStatus,
    ClaraQueryRequest,
    ClaraQueryResult,
    ClaraTrainRequest,
    ClaraTrainStatus,
    DocChunk,
    GroundednessRequest,
    GroundednessResponse,
)

from clara.compressor import (
    COMPRESSOR_VERSION,
    compute_source_offsets,
    encode_texts,
    get_dims,
    save_index,
)
from clara.retriever import generate_answer, retrieve

logger = logging.getLogger("clara.routes")

router = APIRouter()

# ── In-memory job trackers ───────────────────────────────────────

_jobs: dict[str, ClaraIngestStatus] = {}
_train_jobs: dict[str, ClaraTrainStatus] = {}


# ── Health check ─────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "clara", "compressor": COMPRESSOR_VERSION}


# ── Ingest ───────────────────────────────────────────────────────


@router.post("/clara/ingest", response_model=ClaraIngestStatus)
async def ingest(req: ClaraIngestRequest, background_tasks: BackgroundTasks) -> ClaraIngestStatus:
    """Accept an ingestion request and process in background."""
    job_id = str(uuid.uuid4())
    status = ClaraIngestStatus(job_id=job_id, status="pending", progress=0.0)
    _jobs[job_id] = status
    background_tasks.add_task(_run_ingest, job_id, req.collection_id, req.document_ids)
    return status


@router.get("/clara/ingest/status/{job_id}", response_model=ClaraIngestStatus)
async def ingest_status(job_id: str) -> ClaraIngestStatus:
    """Return current status of an ingestion job."""
    status = _jobs.get(job_id)
    if status is None:
        raise HTTPException(status_code=404, detail=f"Job {job_id} not found")
    return status


async def _run_ingest(
    job_id: str,
    collection_id: str,
    document_ids: list[str],
) -> None:
    """Background task: compress every doc_chunk for the given documents."""
    status = _jobs[job_id]
    status.status = "processing"
    try:
        db = await Database.instance()

        # 1) Collect all chunks for the requested documents
        all_chunks: list[dict[str, Any]] = []
        for i, doc_id in enumerate(document_ids):
            rows = await db.fetchall(
                "SELECT id, document_id, chunk_index, text, token_count, metadata_json "
                "FROM doc_chunks WHERE document_id = ? ORDER BY chunk_index",
                (doc_id,),
            )
            for r in rows:
                all_chunks.append(dict(r))
            status.progress = (i + 1) / (len(document_ids) + 1)

        if not all_chunks:
            status.status = "complete"
            status.progress = 1.0
            logger.warning("ingest job=%s: no chunks found for documents %s", job_id, document_ids)
            return

        # 2) Encode all chunk texts → latent vectors
        texts = [c["text"] for c in all_chunks]
        vectors = encode_texts(texts)  # (N, dims)
        dims = vectors.shape[1]

        # 3) Store vectors + mappings in DB
        for idx, chunk in enumerate(all_chunks):
            chunk_id = chunk["id"]
            vec_blob = vectors[idx].tobytes()
            source_offsets = compute_source_offsets(chunk["text"])
            sha = hashlib.sha256(chunk["text"].encode()).hexdigest()

            # Upsert vector
            await db.execute(
                "INSERT OR REPLACE INTO clara_vectors "
                "(doc_chunk_id, vector_blob, dims, compressor_version) VALUES (?, ?, ?, ?)",
                (chunk_id, vec_blob, dims, COMPRESSOR_VERSION),
            )
            # Upsert mapping
            await db.execute(
                "INSERT OR REPLACE INTO clara_mappings "
                "(doc_chunk_id, source_offsets_json, sha256) VALUES (?, ?, ?)",
                (chunk_id, source_offsets, sha),
            )

        await db.commit()

        # 4) Rebuild collection index —
        #    gather ALL vectors that belong to this collection's documents
        coll_rows = await db.fetchall(
            "SELECT dc.id, cv.vector_blob "
            "FROM doc_chunks dc "
            "JOIN clara_vectors cv ON cv.doc_chunk_id = dc.id "
            "JOIN collection_documents cd ON cd.document_id = dc.document_id "
            "WHERE cd.collection_id = ?",
            (collection_id,),
        )

        if coll_rows:
            coll_chunk_ids = [r["id"] for r in coll_rows]
            coll_vectors = np.stack(
                [np.frombuffer(r["vector_blob"], dtype=np.float32) for r in coll_rows]
            )
            index_path = save_index(INDEXES_DIR / collection_id, coll_chunk_ids, coll_vectors)

            # Record in clara_indexes table
            await db.execute(
                "INSERT OR REPLACE INTO clara_indexes "
                "(collection_id, path, dims) VALUES (?, ?, ?)",
                (collection_id, str(index_path), dims),
            )
            await db.commit()

        status.status = "complete"
        status.progress = 1.0
        logger.info(
            "ingest job=%s complete: %d chunks, %d dims", job_id, len(all_chunks), dims
        )

    except Exception as exc:
        logger.exception("ingest job=%s failed", job_id)
        status.status = "error"
        status.error = str(exc)


# ── Query ────────────────────────────────────────────────────────


@router.post("/clara/query", response_model=ClaraQueryResult)
async def query(req: ClaraQueryRequest) -> ClaraQueryResult:
    """Query a collection's CLaRa index for top-k similar chunks."""
    try:
        return await retrieve(
            collection_id=req.collection_id,
            query=req.query,
            top_k=req.top_k,
            include_snippets=req.include_snippets,
        )
    except FileNotFoundError:
        raise HTTPException(
            status_code=404,
            detail=f"No CLaRa index found for collection '{req.collection_id}'. Run /clara/ingest first.",
        )
    except Exception as exc:
        logger.exception("query failed")
        raise HTTPException(status_code=500, detail=str(exc))


# ── Answer ───────────────────────────────────────────────────────


@router.post("/clara/answer", response_model=ClaraAnswerResponse)
async def answer(req: ClaraAnswerRequest) -> ClaraAnswerResponse:
    """Retrieve context, generate an answer with citations and groundedness."""
    try:
        return await generate_answer(
            collection_id=req.collection_id,
            query=req.query,
            top_k=req.top_k,
        )
    except FileNotFoundError:
        raise HTTPException(
            status_code=404,
            detail=f"No CLaRa index found for collection '{req.collection_id}'. Run /clara/ingest first.",
        )
    except Exception as exc:
        logger.exception("answer generation failed")
        raise HTTPException(status_code=500, detail=str(exc))


# ── Compression Training ──────────────────────────────────────────


@router.post("/clara/train", response_model=ClaraTrainStatus)
async def train(req: ClaraTrainRequest, background_tasks: BackgroundTasks) -> ClaraTrainStatus:
    """Start compression training on a CLaRa collection."""
    run_id = str(uuid.uuid4())
    status = ClaraTrainStatus(
        run_id=run_id,
        status="pending",
        progress=0.0,
        total_epochs=req.config.epochs,
    )
    _train_jobs[run_id] = status
    background_tasks.add_task(
        _run_clara_training,
        run_id,
        req.collection_id,
        req.config.model_dump(),
        req.incremental,
    )
    return status


@router.get("/clara/train/{run_id}/status", response_model=ClaraTrainStatus)
async def train_status(run_id: str) -> ClaraTrainStatus:
    """Check status of a CLaRa compression training run."""
    status = _train_jobs.get(run_id)
    if status is None:
        raise HTTPException(status_code=404, detail=f"Training run {run_id} not found")
    return status


async def _run_clara_training(
    run_id: str,
    collection_id: str,
    config: dict,
    incremental: bool,
) -> None:
    """Background task: run CLaRa compression training."""
    from clara.trainer import get_trainer

    status = _train_jobs[run_id]
    status.status = "preparing"

    try:
        db = await Database.instance()

        # Gather document chunks from the collection
        rows = await db.fetchall(
            """
            SELECT dc.document_id, dc.text
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

        # Group chunks by document
        doc_chunks: dict[str, list[str]] = {}
        for r in rows:
            doc_id = r["document_id"]
            if doc_id not in doc_chunks:
                doc_chunks[doc_id] = []
            doc_chunks[doc_id].append(r["text"])

        documents = [
            {"doc_id": doc_id, "chunks": chunks}
            for doc_id, chunks in doc_chunks.items()
        ]

        def _progress(pct: float, msg: str) -> None:
            status.progress = pct
            status.status = "training" if pct > 0.10 else "preparing"
            if pct > 0.85:
                status.status = "evaluating"

        # Run training
        trainer = get_trainer()
        result = await trainer.train_compressor(
            documents=documents,
            config=config,
            progress_callback=_progress,
        )

        if not result.success:
            status.status = "error"
            status.error = result.error
            return

        # Evaluate on the same collection (quick sanity check)
        eval_result = await trainer.evaluate(documents)

        status.status = "complete"
        status.progress = 1.0
        status.current_epoch = result.epochs_completed
        status.metrics = {
            **result.metrics,
            "evaluation": eval_result,
            "num_documents": result.num_documents,
            "num_chunks": result.num_chunks,
            "num_training_pairs": result.num_training_pairs,
            "model_path": result.model_path,
        }

        if result.final_loss is not None:
            status.metrics["final_loss"] = result.final_loss

        logger.info(
            "CLaRa training run=%s complete: %d docs, %d chunks, %d pairs",
            run_id,
            result.num_documents,
            result.num_chunks,
            result.num_training_pairs,
        )

    except Exception as exc:
        logger.exception("CLaRa training run=%s failed", run_id)
        status.status = "error"
        status.error = str(exc)


# ── Groundedness ─────────────────────────────────────────────────


def _split_sentences(text: str) -> list[str]:
    """Split text into sentences/claims using simple punctuation rules."""
    import re

    # Split on sentence-ending punctuation followed by whitespace or end
    raw = re.split(r'(?<=[.!?])\s+', text.strip())
    # Filter out very short fragments (less than 4 words)
    return [s.strip() for s in raw if len(s.strip().split()) >= 4]


def _keyword_overlap_score(sentence: str, snippet: str) -> float:
    """Compute a simple keyword overlap score between a sentence and a snippet.

    Returns 0.0 – 1.0 representing the fraction of meaningful words in the
    sentence that appear somewhere in the snippet.
    """
    # Cheap stop-word set — skip very common English words
    _STOP = frozenset(
        "a an the is are was were be been being have has had do does did "
        "will would shall should may might can could to of in for on with "
        "at by from as into through during before after above below between "
        "out off over under again further then once and but or nor not so "
        "yet both either neither each every all any few more most other some "
        "such no only own same than too very it its this that these those "
        "i me my we our you your he him his she her they them their what "
        "which who whom how if when where why".split()
    )

    sentence_words = set(sentence.lower().split()) - _STOP
    if not sentence_words:
        return 0.0

    snippet_lower = snippet.lower()
    matched = sum(1 for w in sentence_words if w in snippet_lower)
    return matched / len(sentence_words)


_SUPPORT_THRESHOLD = 0.35  # fraction of keywords that must match a snippet


@router.post("/clara/groundedness", response_model=GroundednessResponse)
async def groundedness(req: GroundednessRequest) -> GroundednessResponse:
    """Evaluate how well an answer is grounded in source snippets.

    Splits the answer into sentences, checks each against every snippet
    using keyword overlap scoring, and returns the overall groundedness.
    """
    sentences = _split_sentences(req.answer)

    if not sentences:
        return GroundednessResponse(
            score=0.0, supported_count=0, total_count=0, unsupported=[]
        )

    if not req.snippets:
        return GroundednessResponse(
            score=0.0,
            supported_count=0,
            total_count=len(sentences),
            unsupported=sentences,
        )

    supported: list[str] = []
    unsupported: list[str] = []

    for sentence in sentences:
        best_score = max(
            _keyword_overlap_score(sentence, snippet)
            for snippet in req.snippets
        )
        if best_score >= _SUPPORT_THRESHOLD:
            supported.append(sentence)
        else:
            unsupported.append(sentence)

    total = len(sentences)
    supported_count = len(supported)
    score = supported_count / total if total > 0 else 0.0

    return GroundednessResponse(
        score=round(score, 4),
        supported_count=supported_count,
        total_count=total,
        unsupported=unsupported,
    )
