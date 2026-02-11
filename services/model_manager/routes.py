# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""API routes for the Model Manager service."""

from __future__ import annotations

import logging
import sys
import uuid
from pathlib import Path

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from common.config import INFERENCE_PORT, MODELS_DIR
from common.schemas import (
    AIModel,
    AutopilotResult,
    HardwareInfo,
    ModelDownloadRequest,
    ModelDownloadStatus,
    ModelSource,
)

from model_manager import autopilot, downloader, registry
from model_manager.autopilot import BackendModelInfo, fetch_adapters_from_db

logger = logging.getLogger("model_manager.routes")

router = APIRouter()


# ── Request / Response helpers ──

class AddModelRequest(BaseModel):
    """Add a model by HF repo id or local file path."""
    source: ModelSource
    source_ref: str
    name: str | None = None


class RecommendRequest(BaseModel):
    """Request body for the Autopilot recommendation endpoint."""
    hw_info: HardwareInfo
    user_intent: str | None = None
    include_backends: bool = True  # probe inference router for loaded models
    include_adapters: bool = True  # boost models with trained adapters
    query_context: str | None = None  # e.g. active collection name for adapter matching


class VerifyResponse(BaseModel):
    model_id: str
    checksum: str | None
    verified: bool


class MessageResponse(BaseModel):
    message: str


# ── Health ──

@router.get("/health")
async def health_check():
    return {"status": "ok", "service": "model_manager"}


# ── Model CRUD ──

@router.post("/models/add", response_model=AIModel)
async def add_model(req: AddModelRequest):
    """Register a new model and optionally start download."""
    model_id = _slug_from_ref(req.source_ref)
    name = req.name or req.source_ref.split("/")[-1]

    # Check if it's a known curated model
    curated = registry.CURATED_BY_ID.get(model_id)

    if curated:
        model = curated.model_copy()
    else:
        model = AIModel(
            id=model_id,
            name=name,
            source=req.source,
            source_ref=req.source_ref,
        )

    # Register in DB
    model = await registry.add_model(model)

    # Auto-start download for HF models
    if req.source == ModelSource.hf:
        await downloader.start_download(
            model_id=model.id,
            source_ref=req.source_ref,
        )

    return model


@router.get("/models", response_model=list[AIModel])
async def list_models():
    """List all registered models."""
    return await registry.list_models()


@router.get("/models/{model_id}", response_model=AIModel)
async def get_model(model_id: str):
    """Get details for a specific model."""
    model = await registry.get_model(model_id)
    if model is None:
        raise HTTPException(status_code=404, detail=f"Model '{model_id}' not found")
    return model


@router.delete("/models/{model_id}", response_model=MessageResponse)
async def delete_model(model_id: str):
    """Remove a model from registry and cancel any active download."""
    # Cancel download if active
    await downloader.cancel_download(model_id)

    # Remove from DB
    deleted = await registry.delete_model(model_id)
    if not deleted:
        raise HTTPException(status_code=404, detail=f"Model '{model_id}' not found")

    # Clean up files
    model_dir = MODELS_DIR / model_id
    if model_dir.exists():
        import shutil
        shutil.rmtree(model_dir, ignore_errors=True)

    return MessageResponse(message=f"Model '{model_id}' removed successfully.")


# ── Download management ──

@router.get("/models/status/{model_id}", response_model=ModelDownloadStatus)
async def download_status(model_id: str):
    """Get download status for a model."""
    status = downloader.get_download_status(model_id)
    if status is None:
        # Check if model exists and is already complete
        model = await registry.get_model(model_id)
        if model is None:
            raise HTTPException(status_code=404, detail=f"Model '{model_id}' not found")
        # Model exists but no active download — report as complete
        return ModelDownloadStatus(
            model_id=model_id,
            progress=1.0,
            status="complete",
        )
    return status


@router.post("/models/download/{model_id}/pause", response_model=ModelDownloadStatus)
async def pause_download(model_id: str):
    """Pause an active download."""
    status = await downloader.pause_download(model_id)
    if status is None:
        raise HTTPException(status_code=404, detail=f"No active download for '{model_id}'")
    return status


@router.post("/models/download/{model_id}/resume", response_model=ModelDownloadStatus)
async def resume_download(model_id: str):
    """Resume a paused download."""
    status = await downloader.resume_download(model_id)
    if status is None:
        raise HTTPException(status_code=404, detail=f"No download to resume for '{model_id}'")
    return status


# ── Verification ──

@router.post("/models/verify/{model_id}", response_model=VerifyResponse)
async def verify_model(model_id: str):
    """Compute and store checksum for a downloaded model."""
    model = await registry.get_model(model_id)
    if model is None:
        raise HTTPException(status_code=404, detail=f"Model '{model_id}' not found")

    checksum = await downloader.verify_checksum(model_id)
    if checksum is None:
        raise HTTPException(status_code=400, detail=f"No files found for model '{model_id}'")

    # Store checksum in registry
    await registry.update_model_checksum(model_id, checksum)

    verified = True
    if model.checksum and model.checksum != checksum:
        verified = False

    return VerifyResponse(model_id=model_id, checksum=checksum, verified=verified)


# ── Autopilot / Recommendation ──

@router.post("/models/recommend", response_model=AutopilotResult)
async def recommend_models(req: RecommendRequest):
    """Run the Autopilot recommendation algorithm.

    Takes hardware info and optional user intent, returns ranked model
    recommendations. When include_backends is True (default), probes the
    inference router for loaded models in Ollama / LM Studio and boosts
    those in the ranking. When include_adapters is True (default), fetches
    trained adapters from the database and boosts models that have
    personalized adapters.
    """
    backend_models: list[BackendModelInfo] | None = None
    adapter_list: list[autopilot.AdapterInfo] | None = None

    if req.include_backends:
        backend_models = await _fetch_backend_models()

    if req.include_adapters:
        adapter_list = await fetch_adapters_from_db()

    result = autopilot.recommend(
        hw=req.hw_info,
        user_intent=req.user_intent,
        backend_models=backend_models,
        adapters=adapter_list,
        query_context=req.query_context,
    )
    return result


# ── Curated list ──

@router.get("/models/curated", response_model=list[AIModel])
async def get_curated_models():
    """Return the curated list of known-good models."""
    return registry.CURATED_MODELS


# ── Helpers ──

async def _fetch_backend_models() -> list[BackendModelInfo]:
    """Probe the inference router for models available in Ollama / LM Studio."""
    models: list[BackendModelInfo] = []
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            # Probe Ollama
            resp = await client.get(f"http://127.0.0.1:11434/api/tags")
            if resp.status_code == 200:
                data = resp.json()
                for m in data.get("models", []):
                    name = m.get("name", "")
                    if name:
                        models.append(BackendModelInfo(
                            model_name=name,
                            backend="ollama",
                            loaded=False,
                        ))

            # Check which model is currently loaded (warm) in Ollama
            try:
                ps_resp = await client.get(f"http://127.0.0.1:11434/api/ps")
                if ps_resp.status_code == 200:
                    ps_data = ps_resp.json()
                    loaded_names = {
                        m.get("name", "")
                        for m in ps_data.get("models", [])
                    }
                    for bm in models:
                        if bm.model_name in loaded_names:
                            bm.loaded = True
            except Exception:
                pass

    except Exception:
        logger.debug("Could not probe Ollama for backend models")

    return models


def _slug_from_ref(source_ref: str) -> str:
    """Generate a stable slug id from a source reference.

    "bartowski/Llama-3.2-1B-Instruct-GGUF" → "llama-3.2-1b-instruct-gguf"
    """
    # Take the repo name part (after /)
    parts = source_ref.strip("/").split("/")
    name = parts[-1] if parts else source_ref

    # Lowercase and clean
    slug = name.lower().replace("_", "-").replace(" ", "-")

    # Remove consecutive hyphens
    while "--" in slug:
        slug = slug.replace("--", "-")

    return slug.strip("-")
