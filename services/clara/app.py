# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc CLaRa Service — FastAPI entry point.

Compression-native RAG: document ingestion, latent vector retrieval,
and cited answer generation.
Runs on port 8103, localhost only.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the common package is importable
sys.path.insert(0, str(Path(__file__).parent.parent))

import logging
from contextlib import asynccontextmanager
from typing import AsyncIterator

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from clara.routes import router
from common.config import CLARA_PORT, SERVICE_HOST, ensure_dirs
from common.database import Database

# ── Logging setup ────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-20s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    ensure_dirs()
    await Database.instance()  # warm up the singleton
    try:
        yield
    finally:
        db = await Database.instance()
        await db.close()


# ── App ──────────────────────────────────────────────────────────

app = FastAPI(
    title="Studiomc CLaRa Service",
    version="0.1.0",
    description="Compression-native RAG: ingest, retrieve, and answer with citations.",
    lifespan=lifespan,
)

# CORS — allow the Electron front-end on any localhost port
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:*", "http://127.0.0.1:*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)


# ── CLI entry point ──────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=CLARA_PORT,
        reload=False,
        log_level="info",
    )
