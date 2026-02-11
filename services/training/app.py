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
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from common.config import TRAINING_PORT, ensure_dirs
from common.database import Database
from training.routes import router

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-20s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)

app = FastAPI(
    title="Studiomc Training Service",
    version="0.1.0",
    description="Local LoRA adapter training from documents or extracts.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router)

@app.on_event("startup")
async def _startup() -> None:
    ensure_dirs()
    await Database.instance()

@app.on_event("shutdown")
async def _shutdown() -> None:
    db = await Database.instance()
    await db.close()

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=TRAINING_PORT, reload=False, log_level="info")
