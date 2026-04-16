# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc Document Service — FastAPI entry point.

Handles document upload, text extraction, chunking, and basic retrieval.
Runs on port 8102, localhost only.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the common package is importable
sys.path.insert(0, str(Path(__file__).parent.parent))

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from common.config import DOCUMENT_PORT, SERVICE_HOST, ensure_dirs
from common.database import Database

from documents.routes import router

app = FastAPI(
    title="Studiomc Document Service",
    version="0.1.0",
    description="Upload, extract, chunk, and retrieve documents.",
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
        port=DOCUMENT_PORT,
        reload=False,
        log_level="info",
    )
