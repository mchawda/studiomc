# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc Training Service — FastAPI entry point.

Local LoRA adapter training: train from document collections (CLaRa)
or user-provided extracts (Q&A, facts, summaries).
Runs on port 8106, localhost only.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from common.config import SERVICE_HOST, SUPERVISOR_PORT, TRAINING_PORT, ensure_dirs, service_url
from common.database import Database
from common.fastapi_pro_pack import install_pro_pack_handler
from training.routes import router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-20s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)


# Background HTTP client used by the touch middleware. One per process,
# created lazily so import-time stays cheap.
_touch_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    ensure_dirs()
    await Database.instance()
    try:
        yield
    finally:
        global _touch_client
        if _touch_client is not None:
            await _touch_client.aclose()
            _touch_client = None
        db = await Database.instance()
        await db.close()


app = FastAPI(
    title="Studiomc Training Service",
    version="0.1.0",
    description="Local LoRA adapter training from documents or extracts.",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)
install_pro_pack_handler(app)


# ── Root health (non-prefixed, for supervisor probes) ────────────────────
# The training APIRouter is mounted under ``/training`` so the router-level
# ``/health`` resolves to ``/training/health``. The supervisor probes
# ``/health`` at the root, so re-expose it here. Keep this above the
# ``_supervisor_touch`` middleware so the path-skip in that middleware
# (``request.url.path != "/health"``) keeps the probe out of the touch loop.
@app.get("/health")
async def root_health() -> dict[str, str]:
    return {"status": "ok", "service": "training"}


@app.middleware("http")
async def _supervisor_touch(request: Request, call_next):
    """Tell the supervisor we're still busy on every request.

    The supervisor evicts the (heavy, Pro-pack-only) training service
    after :data:`IDLE_EVICT_SECONDS` of no /touch pings, freeing the
    ~2-3 GB of RAM PyTorch holds open. Skipping ``/health`` keeps the
    supervisor's own health-check probes from accidentally counting as
    activity.
    """
    response = await call_next(request)
    if request.url.path != "/health":
        global _touch_client
        if _touch_client is None:
            _touch_client = httpx.AsyncClient(timeout=2.0)
        try:
            await _touch_client.post(
                service_url(SUPERVISOR_PORT, "/services/training/touch")
            )
        except Exception:
            # Supervisor may have shut down ahead of us — never propagate.
            pass
    return response

if __name__ == "__main__":
    uvicorn.run(app, host=SERVICE_HOST, port=TRAINING_PORT, reload=False, log_level="info")
