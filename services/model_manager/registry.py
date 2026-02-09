"""Model registry — CRUD operations and curated model catalog.

Persists registered models in SQLite via the shared Database layer.
The curated list is a hardcoded catalog of known-good GGUF models.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from common.database import Database
from common.schemas import AIModel, ModelSource


# ── Curated Model Catalog ──

CURATED_MODELS: list[AIModel] = [
    AIModel(
        id="llama-3.2-1b-q4km",
        name="Llama 3.2 1B (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Llama-3.2-1B-Instruct-GGUF",
        params_billion=1.24,
        quant="Q4_K_M",
        disk_bytes=780_000_000,           # ~780 MB
        arch="llama",
        context_max=131072,
    ),
    AIModel(
        id="llama-3.2-3b-q4km",
        name="Llama 3.2 3B (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Llama-3.2-3B-Instruct-GGUF",
        params_billion=3.21,
        quant="Q4_K_M",
        disk_bytes=2_020_000_000,         # ~2.0 GB
        arch="llama",
        context_max=131072,
    ),
    AIModel(
        id="llama-3.2-8b-q4km",
        name="Llama 3.2 8B (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
        params_billion=8.03,
        quant="Q4_K_M",
        disk_bytes=4_920_000_000,         # ~4.9 GB
        arch="llama",
        context_max=131072,
    ),
    AIModel(
        id="phi-3-mini-3.8b-q4km",
        name="Phi-3 Mini 3.8B (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Phi-3.5-mini-instruct-GGUF",
        params_billion=3.82,
        quant="Q4_K_M",
        disk_bytes=2_390_000_000,         # ~2.4 GB
        arch="phi3",
        context_max=131072,
    ),
    AIModel(
        id="mistral-7b-instruct-q4km",
        name="Mistral 7B Instruct (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Mistral-7B-Instruct-v0.3-GGUF",
        params_billion=7.25,
        quant="Q4_K_M",
        disk_bytes=4_370_000_000,         # ~4.4 GB
        arch="mistral",
        context_max=32768,
    ),
    AIModel(
        id="qwen-2.5-7b-q4km",
        name="Qwen 2.5 7B (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Qwen2.5-7B-Instruct-GGUF",
        params_billion=7.62,
        quant="Q4_K_M",
        disk_bytes=4_680_000_000,         # ~4.7 GB
        arch="qwen2",
        context_max=131072,
    ),
    AIModel(
        id="llama-3.1-70b-q4km",
        name="Llama 3.1 70B (Q4_K_M)",
        source=ModelSource.hf,
        source_ref="bartowski/Meta-Llama-3.1-70B-Instruct-GGUF",
        params_billion=70.55,
        quant="Q4_K_M",
        disk_bytes=40_800_000_000,        # ~40.8 GB
        arch="llama",
        context_max=131072,
    ),
]

CURATED_BY_ID: dict[str, AIModel] = {m.id: m for m in CURATED_MODELS}


# ── Registry CRUD ──

async def add_model(model: AIModel) -> AIModel:
    """Insert a new model into the database. Returns the model with generated id if needed."""
    if not model.id:
        model.id = str(uuid.uuid4())

    db = await Database.instance()
    await db.execute(
        """INSERT OR REPLACE INTO models
           (id, name, source, source_ref, params_billion, quant, disk_bytes,
            arch, context_max, checksum, manifest_json, created_at, last_used_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            model.id,
            model.name,
            model.source.value,
            model.source_ref,
            model.params_billion,
            model.quant,
            model.disk_bytes,
            model.arch,
            model.context_max,
            model.checksum,
            model.manifest_json,
            model.created_at.isoformat(),
            model.last_used_at.isoformat() if model.last_used_at else None,
        ),
    )
    await db.commit()
    return model


async def get_model(model_id: str) -> AIModel | None:
    """Fetch a single model by id."""
    db = await Database.instance()
    row = await db.fetchone("SELECT * FROM models WHERE id = ?", (model_id,))
    if row is None:
        return None
    return _row_to_model(row)


async def list_models() -> list[AIModel]:
    """Return all registered models."""
    db = await Database.instance()
    rows = await db.fetchall("SELECT * FROM models ORDER BY created_at DESC")
    return [_row_to_model(r) for r in rows]


async def delete_model(model_id: str) -> bool:
    """Delete model from registry. Returns True if a row was deleted."""
    db = await Database.instance()
    cursor = await db.execute("DELETE FROM models WHERE id = ?", (model_id,))
    await db.commit()
    return cursor.rowcount > 0


async def update_model_checksum(model_id: str, checksum: str) -> None:
    """Update the checksum field after verification."""
    db = await Database.instance()
    await db.execute(
        "UPDATE models SET checksum = ? WHERE id = ?",
        (checksum, model_id),
    )
    await db.commit()


async def touch_model(model_id: str) -> None:
    """Update last_used_at timestamp."""
    db = await Database.instance()
    await db.execute(
        "UPDATE models SET last_used_at = ? WHERE id = ?",
        (datetime.utcnow().isoformat(), model_id),
    )
    await db.commit()


def _row_to_model(row) -> AIModel:
    """Convert a sqlite Row to an AIModel."""
    return AIModel(
        id=row["id"],
        name=row["name"],
        source=ModelSource(row["source"]),
        source_ref=row["source_ref"],
        params_billion=row["params_billion"],
        quant=row["quant"],
        disk_bytes=row["disk_bytes"],
        arch=row["arch"],
        context_max=row["context_max"],
        checksum=row["checksum"],
        manifest_json=row["manifest_json"],
        created_at=datetime.fromisoformat(row["created_at"]) if row["created_at"] else datetime.utcnow(),
        last_used_at=datetime.fromisoformat(row["last_used_at"]) if row["last_used_at"] else None,
    )
