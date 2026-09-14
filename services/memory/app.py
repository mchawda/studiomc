# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc Memory Service — FastAPI entry point on port 8109."""

from __future__ import annotations

import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from contextlib import asynccontextmanager  # noqa: E402
from typing import AsyncIterator  # noqa: E402

import uvicorn  # noqa: E402
from fastapi import FastAPI  # noqa: E402

from common.config import MEMORY_PORT, SERVICE_HOST, ensure_dirs  # noqa: E402
from common.database import Database  # noqa: E402
from memory.routes import router  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(name)-22s | %(levelname)-5s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("memory")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    ensure_dirs()
    await Database.instance()
    logger.info("Memory service ready on %s:%d", SERVICE_HOST, MEMORY_PORT)
    yield


app = FastAPI(
    title="Studiomc Memory Service",
    description=(
        "Persistent cross-conversation memory store. Auto-extracts and "
        "retrieves long-lived facts, preferences, and project context."
    ),
    version="0.1.0",
    lifespan=lifespan,
)
app.include_router(router)


if __name__ == "__main__":
    uvicorn.run(app, host=SERVICE_HOST, port=MEMORY_PORT, log_level="info")
