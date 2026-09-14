# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Data Recipes Service — auto-generate training datasets from documents.

Takes raw documents (PDF, CSV, JSON, TXT, DOCX) and transforms them
into training-ready datasets in multiple formats (JSONL chat, Alpaca,
ShareGPT). Leverages CLaRa's extraction pipeline and local LLM
inference for high-quality Q&A pair generation.

Runs on port 8107, localhost only.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from common.config import DATA_RECIPES_PORT, SERVICE_HOST, ensure_dirs
from common.database import Database
from data_recipes.routes import router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-20s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    ensure_dirs()
    await Database.instance()
    try:
        yield
    finally:
        db = await Database.instance()
        await db.close()


app = FastAPI(
    title="Studiomc Data Recipes Service",
    version="0.1.0",
    description="Auto-generate training datasets from documents.",
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


# ── Root health (non-prefixed, for supervisor probes) ────────────────────
# The data_recipes APIRouter is mounted under ``/recipes`` so the
# router-level ``/health`` resolves to ``/recipes/health``. The supervisor
# probes ``/health`` at the root, so re-expose it here.
@app.get("/health")
async def root_health() -> dict[str, str]:
    return {"status": "ok", "service": "data_recipes"}


if __name__ == "__main__":
    uvicorn.run(
        app, host=SERVICE_HOST, port=DATA_RECIPES_PORT, reload=False, log_level="info"
    )
