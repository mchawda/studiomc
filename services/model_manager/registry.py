# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Model registry — CRUD operations and curated model catalog.

Persists registered models in SQLite via the shared Database layer.
The curated list is a hardcoded catalog of known-good GGUF models.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime

from common.database import Database
from common.schemas import AIModel, ModelSource

# Studiomc 4B is the Autopilot desktop default when hardware fits (~3-6 GB).
# Keep this id aligned with training.studiomc_model.recipe.SPECIALIZED_MODEL_ID.
STUDIOMC_4B_ID = "studiomc-4b"
# Studiomc 0.6B is the phone-tier sibling. Same Qwen3 family so a phone SFT
# reuses the 4B recipe. The mobile catalog (studiomc_app/.../catalog.dart)
# must list exactly these Studiomc ids; tests/test_studiomc_model.py checks.
STUDIOMC_06B_ID = "studiomc-0.6b"
STUDIOMC_IDS: frozenset[str] = frozenset({STUDIOMC_4B_ID, STUDIOMC_06B_ID})
_DESKTOP_DEFAULT_PARAMS = (3.0, 6.0)

# Upstream artefacts (verified against the HuggingFace API; sha256 is the
# LFS digest, which is what ``downloader.verify_checksum`` computes).
STUDIOMC_4B_GGUF_REPO = "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF"
STUDIOMC_4B_GGUF_FILE = "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
STUDIOMC_4B_GGUF_BYTES = 2_497_280_736
STUDIOMC_4B_GGUF_SHA256 = (
    "2fde00ce69dd4899c70d020845e2638353015bba0fdf161b3eb965f2bca4464e"
)
STUDIOMC_06B_GGUF_REPO = "bartowski/Qwen_Qwen3-0.6B-GGUF"
STUDIOMC_06B_GGUF_FILE = "Qwen_Qwen3-0.6B-Q4_K_M.gguf"
STUDIOMC_06B_GGUF_BYTES = 484_220_320
STUDIOMC_06B_GGUF_SHA256 = (
    "9acfc1e001311f34b4252001b626f2e466d592a42065f66571bff3790d4e1b14"
)
# Qwen3 weights and the bartowski quantisations are Apache-2.0.
STUDIOMC_BASE_LICENSE = "Apache-2.0"


def is_studiomc_specialized(model: AIModel) -> bool:
    """True for Studiomc-branded catalog / registry entries."""
    mid = (model.id or "").lower()
    nm = (model.name or "").lower()
    return mid.startswith("studiomc-") or nm.startswith("studiomc")


def catalog_role(model: AIModel) -> str | None:
    """``role`` from ``manifest_json`` (``desktop_default``, ``mobile_default``)."""
    if not model.manifest_json:
        return None
    try:
        card = json.loads(model.manifest_json)
    except (TypeError, ValueError):
        return None
    role = card.get("role") if isinstance(card, dict) else None
    return str(role) if role else None


def is_mobile_tier(model: AIModel) -> bool:
    """Phone-tier catalog entries; desktop Autopilot never ranks these."""
    return catalog_role(model) == "mobile_default"


def is_desktop_default_candidate(model: AIModel) -> bool:
    """Studiomc 3-6B model Autopilot may pin as the desktop default."""
    if not is_studiomc_specialized(model):
        return False
    params = model.params_billion or 0.0
    lo, hi = _DESKTOP_DEFAULT_PARAMS
    return lo <= params <= hi


# ── Curated Model Catalog ──

CURATED_MODELS: list[AIModel] = [
    AIModel(
        id=STUDIOMC_4B_ID,
        name="Studiomc 4B",
        source=ModelSource.hf,
        source_ref=STUDIOMC_4B_GGUF_REPO,
        params_billion=4.0,
        quant="Q4_K_M",
        disk_bytes=STUDIOMC_4B_GGUF_BYTES,  # 2.50 GB Q4_K_M
        arch="qwen3",
        context_max=262144,
        checksum=STUDIOMC_4B_GGUF_SHA256,
        manifest_json=json.dumps({
            "brand": "studiomc",
            "role": "desktop_default",
            "specialization": ["grounded_qa", "citations", "lre_tools"],
            "base": "Qwen/Qwen3-4B-Instruct-2507",
            "license": STUDIOMC_BASE_LICENSE,
            "gguf_file": STUDIOMC_4B_GGUF_FILE,
            "sha256": STUDIOMC_4B_GGUF_SHA256,
            # Q4_K_M weights + 4K KV cache + runtime headroom.
            "min_ram_bytes": 8 * 1024**3,
            "min_vram_bytes": 3 * 1024**3,
            "thinking": False,
        }),
    ),
    AIModel(
        id=STUDIOMC_06B_ID,
        name="Studiomc 0.6B",
        source=ModelSource.hf,
        source_ref=STUDIOMC_06B_GGUF_REPO,
        params_billion=0.6,
        quant="Q4_K_M",
        disk_bytes=STUDIOMC_06B_GGUF_BYTES,  # 0.48 GB Q4_K_M
        arch="qwen3",
        context_max=32768,
        checksum=STUDIOMC_06B_GGUF_SHA256,
        manifest_json=json.dumps({
            "brand": "studiomc",
            "role": "mobile_default",
            "specialization": ["grounded_qa", "citations"],
            "base": "Qwen/Qwen3-0.6B",
            "license": STUDIOMC_BASE_LICENSE,
            "gguf_file": STUDIOMC_06B_GGUF_FILE,
            "sha256": STUDIOMC_06B_GGUF_SHA256,
            "min_ram_bytes": 3 * 1024**3,
            "min_vram_bytes": 0,
            # Qwen3-0.6B is a hybrid thinking model; hosts must pass
            # enable_thinking=false or strip <think> blocks.
            "thinking": True,
            "chat_template_kwargs": {"enable_thinking": False},
        }),
    ),
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
