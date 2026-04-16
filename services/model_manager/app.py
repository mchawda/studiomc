# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Model Manager Service — FastAPI entrypoint.

Handles model downloading, verification, registry, and Autopilot recommendations.
Runs on 127.0.0.1:8101.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the services package root is on the path so `from common.…` works
sys.path.insert(0, str(Path(__file__).parent.parent))

import logging
import uvicorn
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from common.config import MODEL_MANAGER_PORT, SERVICE_HOST, ensure_dirs
from common.database import Database

from model_manager.routes import router

logger = logging.getLogger("model_manager")


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup / shutdown lifecycle."""
    # ── Startup ──
    ensure_dirs()
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )
    logger.info("Model Manager starting on port %d", MODEL_MANAGER_PORT)

    # Initialize database connection
    await Database.instance()
    logger.info("Database connected.")

    yield

    # ── Shutdown ──
    db = await Database.instance()
    await db.close()
    logger.info("Model Manager shut down.")


app = FastAPI(
    title="Studiomc Model Manager",
    description="Manage AI model downloads, registry, and Autopilot recommendations.",
    version="0.1.0",
    lifespan=lifespan,
)

# Allow the Electron frontend to call us
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount all routes
app.include_router(router)


def main() -> None:
    """Run the service directly: python -m model_manager.app"""
    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=MODEL_MANAGER_PORT,
        reload=False,
        log_level="info",
    )


if __name__ == "__main__":
    main()
