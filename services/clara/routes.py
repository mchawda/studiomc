"""CLaRa API routes.

Endpoints:
  POST /clara/ingest         — Ingest docs → chunks → latent vectors (background job)
  GET  /clara/ingest/status/{job_id} — Check ingestion progress
  POST /clara/query          — Query → top-k latent vectors + optional snippets
  POST /clara/answer         — Query + vectors → answer + citations + groundedness
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
    DocChunk,
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

# ── In-memory job tracker ────────────────────────────────────────

_jobs: dict[str, ClaraIngestStatus] = {}


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
