"""API routes for the Document Service.

All routes are mounted under the FastAPI app in app.py.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, HTTPException, UploadFile, File
from pydantic import BaseModel

from common.config import DOCS_DIR
from common.database import Database
from common.schemas import DocStatus

from documents import extractor, chunker

router = APIRouter()


# ── Request / Response helpers ───────────────────────────────────


class CollectionCreate(BaseModel):
    name: str


class AddDocRequest(BaseModel):
    document_id: str


class CollectionQueryRequest(BaseModel):
    query: str
    limit: int = 20


# ── Background task: extract + chunk pipeline ───────────────────


async def _process_document(doc_id: str, original_path: Path) -> None:
    """Run extraction → chunking pipeline.  Updates status at each stage."""
    db = await Database.instance()
    try:
        # 1. Compute SHA-256
        sha256 = extractor.compute_sha256(original_path)
        await db.execute(
            "UPDATE documents SET sha256 = ? WHERE id = ?", (sha256, doc_id)
        )
        await db.commit()

        # 2. Extract text
        await db.execute(
            "UPDATE documents SET status = ? WHERE id = ?",
            (DocStatus.extracting.value, doc_id),
        )
        await db.commit()

        text = await extractor.extract_text(doc_id, original_path)

        # 3. Chunk
        await db.execute(
            "UPDATE documents SET status = ? WHERE id = ?",
            (DocStatus.chunking.value, doc_id),
        )
        await db.commit()

        await chunker.chunk_and_store(doc_id, text)

        # 4. Ready
        await db.execute(
            "UPDATE documents SET status = ? WHERE id = ?",
            (DocStatus.ready.value, doc_id),
        )
        await db.commit()

    except Exception as exc:
        await db.execute(
            "UPDATE documents SET status = ?, error_message = ? WHERE id = ?",
            (DocStatus.error.value, str(exc)[:500], doc_id),
        )
        await db.commit()


# ── Document endpoints ───────────────────────────────────────────


@router.post("/docs/upload")
async def upload_document(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...),
):
    """Upload a document (PDF, TXT, MD).  Returns doc_id immediately."""
    filename = file.filename or "untitled"
    ext = Path(filename).suffix.lower()

    if ext not in extractor.SUPPORTED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported file type '{ext}'. Supported: {', '.join(extractor.SUPPORTED_EXTENSIONS)}",
        )

    content = await file.read()

    if len(content) > extractor.MAX_FILE_BYTES:
        raise HTTPException(
            status_code=413,
            detail=f"File too large ({len(content)} bytes). Max: {extractor.MAX_FILE_BYTES} bytes.",
        )

    doc_id = uuid.uuid4().hex
    mime = extractor.MIME_MAP.get(ext)

    # Save original file
    original_path = await extractor.save_upload(doc_id, filename, content)

    # Insert DB record
    db = await Database.instance()
    await db.execute(
        """INSERT INTO documents (id, filename, mime, bytes, status, created_at)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (doc_id, filename, mime, len(content), DocStatus.uploaded.value, datetime.utcnow().isoformat()),
    )
    await db.commit()

    # Kick off extraction in background
    background_tasks.add_task(_process_document, doc_id, original_path)

    return {"doc_id": doc_id, "filename": filename, "status": DocStatus.uploaded.value}


@router.get("/docs")
async def list_documents():
    """List all documents."""
    db = await Database.instance()
    rows = await db.fetchall(
        "SELECT id, filename, mime, bytes, sha256, status, error_message, created_at FROM documents ORDER BY created_at DESC"
    )
    return [dict(r) for r in rows]


@router.get("/docs/{doc_id}")
async def get_document(doc_id: str):
    """Get a single document's details."""
    db = await Database.instance()
    row = await db.fetchone(
        "SELECT id, filename, mime, bytes, sha256, status, error_message, created_at FROM documents WHERE id = ?",
        (doc_id,),
    )
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")
    return dict(row)


@router.delete("/docs/{doc_id}")
async def delete_document(doc_id: str):
    """Delete a document and all its chunks.  Also removes files on disk."""
    db = await Database.instance()
    row = await db.fetchone("SELECT id FROM documents WHERE id = ?", (doc_id,))
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")

    # Remove DB records (cascading deletes handle doc_chunks + collection_documents)
    await db.execute("DELETE FROM documents WHERE id = ?", (doc_id,))
    await db.commit()

    # Remove files
    import shutil

    doc_path = DOCS_DIR / doc_id
    if doc_path.exists():
        shutil.rmtree(doc_path)

    return {"deleted": doc_id}


@router.post("/docs/extract/{doc_id}")
async def extract_document(doc_id: str, background_tasks: BackgroundTasks):
    """Manually trigger (re-)extraction for an already-uploaded document."""
    db = await Database.instance()
    row = await db.fetchone(
        "SELECT id, filename, status FROM documents WHERE id = ?", (doc_id,)
    )
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")

    # Find the original file on disk
    doc_path = DOCS_DIR / doc_id
    originals = list(doc_path.glob("original.*")) if doc_path.exists() else []
    if not originals:
        raise HTTPException(status_code=404, detail="Original file not found on disk")

    # Clear old chunks before re-extraction
    await db.execute("DELETE FROM doc_chunks WHERE document_id = ?", (doc_id,))
    await db.execute(
        "UPDATE documents SET status = ?, error_message = NULL WHERE id = ?",
        (DocStatus.uploaded.value, doc_id),
    )
    await db.commit()

    background_tasks.add_task(_process_document, doc_id, originals[0])

    return {"doc_id": doc_id, "status": "extraction_started"}


@router.get("/docs/{doc_id}/chunks")
async def get_chunks(doc_id: str):
    """Return all chunks for a document, ordered by index."""
    db = await Database.instance()

    # Verify document exists
    row = await db.fetchone("SELECT id FROM documents WHERE id = ?", (doc_id,))
    if not row:
        raise HTTPException(status_code=404, detail="Document not found")

    rows = await db.fetchall(
        "SELECT id, document_id, chunk_index, text, token_count, metadata_json FROM doc_chunks WHERE document_id = ? ORDER BY chunk_index",
        (doc_id,),
    )
    return [dict(r) for r in rows]


# ── Collection endpoints ─────────────────────────────────────────


@router.post("/collections/create")
async def create_collection(body: CollectionCreate):
    """Create a new collection."""
    coll_id = uuid.uuid4().hex
    db = await Database.instance()
    await db.execute(
        "INSERT INTO collections (id, name, created_at) VALUES (?, ?, ?)",
        (coll_id, body.name, datetime.utcnow().isoformat()),
    )
    await db.commit()
    return {"id": coll_id, "name": body.name}


@router.get("/collections")
async def list_collections():
    """List all collections with document counts."""
    db = await Database.instance()
    rows = await db.fetchall(
        """SELECT c.id, c.name, c.created_at, COUNT(cd.document_id) AS doc_count
           FROM collections c
           LEFT JOIN collection_documents cd ON c.id = cd.collection_id
           GROUP BY c.id
           ORDER BY c.created_at DESC"""
    )
    return [dict(r) for r in rows]


@router.get("/collections/{collection_id}")
async def get_collection(collection_id: str):
    """Get collection details with document count."""
    db = await Database.instance()
    row = await db.fetchone(
        """SELECT c.id, c.name, c.created_at, COUNT(cd.document_id) AS doc_count
           FROM collections c
           LEFT JOIN collection_documents cd ON c.id = cd.collection_id
           WHERE c.id = ?
           GROUP BY c.id""",
        (collection_id,),
    )
    if not row:
        raise HTTPException(status_code=404, detail="Collection not found")
    return dict(row)


@router.post("/collections/{collection_id}/add-doc")
async def add_doc_to_collection(collection_id: str, body: AddDocRequest):
    """Add a document to a collection."""
    db = await Database.instance()

    # Verify collection exists
    coll = await db.fetchone("SELECT id FROM collections WHERE id = ?", (collection_id,))
    if not coll:
        raise HTTPException(status_code=404, detail="Collection not found")

    # Verify document exists
    doc = await db.fetchone("SELECT id FROM documents WHERE id = ?", (body.document_id,))
    if not doc:
        raise HTTPException(status_code=404, detail="Document not found")

    # Check if already added
    existing = await db.fetchone(
        "SELECT 1 FROM collection_documents WHERE collection_id = ? AND document_id = ?",
        (collection_id, body.document_id),
    )
    if existing:
        return {"status": "already_exists"}

    await db.execute(
        "INSERT INTO collection_documents (collection_id, document_id) VALUES (?, ?)",
        (collection_id, body.document_id),
    )
    await db.commit()
    return {"status": "added", "collection_id": collection_id, "document_id": body.document_id}


@router.delete("/collections/{collection_id}")
async def delete_collection(collection_id: str):
    """Delete a collection (documents are NOT deleted, only the association)."""
    db = await Database.instance()
    row = await db.fetchone("SELECT id FROM collections WHERE id = ?", (collection_id,))
    if not row:
        raise HTTPException(status_code=404, detail="Collection not found")

    await db.execute("DELETE FROM collections WHERE id = ?", (collection_id,))
    await db.commit()
    return {"deleted": collection_id}


@router.post("/collections/{collection_id}/query")
async def query_collection(collection_id: str, body: CollectionQueryRequest):
    """Basic text search across all chunks in a collection.

    Uses SQLite LIKE for substring matching.  A future version will use
    vector similarity via CLaRa.
    """
    db = await Database.instance()

    # Verify collection exists
    coll = await db.fetchone("SELECT id FROM collections WHERE id = ?", (collection_id,))
    if not coll:
        raise HTTPException(status_code=404, detail="Collection not found")

    search_term = f"%{body.query}%"
    rows = await db.fetchall(
        """SELECT dc.id, dc.document_id, dc.chunk_index, dc.text, dc.token_count,
                  d.filename
           FROM doc_chunks dc
           JOIN collection_documents cd ON dc.document_id = cd.document_id
           JOIN documents d ON d.id = dc.document_id
           WHERE cd.collection_id = ?
             AND dc.text LIKE ?
           ORDER BY dc.document_id, dc.chunk_index
           LIMIT ?""",
        (collection_id, search_term, body.limit),
    )
    return {
        "query": body.query,
        "results": [dict(r) for r in rows],
        "count": len(rows),
    }


# ── Health ───────────────────────────────────────────────────────


@router.get("/health")
async def health():
    return {"service": "documents", "status": "ok"}
