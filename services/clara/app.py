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

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from common.config import CLARA_PORT, SERVICE_HOST, ensure_dirs
from common.database import Database

from clara.routes import router

# ── Logging setup ────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-20s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)

# ── App ──────────────────────────────────────────────────────────

app = FastAPI(
    title="Studiomc CLaRa Service",
    version="0.1.0",
    description="Compression-native RAG: ingest, retrieve, and answer with citations.",
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


# ── Lifecycle events ─────────────────────────────────────────────


@app.on_event("startup")
async def _startup() -> None:
    ensure_dirs()
    await Database.instance()  # warm up the singleton


@app.on_event("shutdown")
async def _shutdown() -> None:
    db = await Database.instance()
    await db.close()


# ── CLI entry point ──────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=CLARA_PORT,
        reload=False,
        log_level="info",
    )
