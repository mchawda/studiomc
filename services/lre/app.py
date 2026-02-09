"""LRE Service — FastAPI application entry point.

Local Reasoning Environment: a sandboxed tool runtime for Investigate mode.
Binds to 127.0.0.1:8104 (localhost only — never exposed to the network).

Start with:
    python -m services.lre.app
or:
    uvicorn services.lre.app:app --host 127.0.0.1 --port 8104
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the services package root is importable
sys.path.insert(0, str(Path(__file__).parent.parent))

from contextlib import asynccontextmanager
from typing import AsyncIterator

import uvicorn
from fastapi import FastAPI

from common.config import LRE_PORT
from common.database import Database

from lre.routes import router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup / shutdown lifecycle."""
    # Warm up the database connection
    await Database.instance()
    yield
    # Graceful shutdown
    db = await Database.instance()
    await db.close()


app = FastAPI(
    title="Studiomc LRE",
    description=(
        "Local Reasoning Environment — sandboxed tool runtime for "
        "Investigate mode. Provides allowlisted read-only operations only."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(router)


# ── Root health (non-prefixed convenience) ──────────────────────────────


@app.get("/health")
async def root_health() -> dict[str, str]:
    return {"status": "ok", "service": "lre"}


# ── Main ────────────────────────────────────────────────────────────────


if __name__ == "__main__":
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=LRE_PORT,
        log_level="info",
    )
