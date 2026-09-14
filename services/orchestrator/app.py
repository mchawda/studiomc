# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Recursive Orchestrator Service — FastAPI application entrypoint.

Starts on 127.0.0.1:8105.  Implements the RLM-style reasoning loop
(plan → tool → observe → answer / sub-query) across fast, cited, and
investigate modes with strict budget enforcement.

Run directly:
    python -m services.orchestrator.app
or:
    python services/orchestrator/app.py
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

# ── Path fixup so ``from common.…`` works when run as a script ──────
sys.path.insert(0, str(Path(__file__).parent.parent))

from contextlib import asynccontextmanager  # noqa: E402
from typing import AsyncIterator  # noqa: E402

from fastapi import FastAPI  # noqa: E402

from common.config import ORCHESTRATOR_PORT, SERVICE_HOST  # noqa: E402
from orchestrator.routes import router  # noqa: E402

# ── Logging ─────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(name)-28s | %(levelname)-5s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("orchestrator")


# ── Lifespan ────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    logger.info("Orchestrator starting on %s:%d", SERVICE_HOST, ORCHESTRATOR_PORT)
    try:
        yield
    finally:
        logger.info("Orchestrator shutting down")


# ── FastAPI app ─────────────────────────────────────────────────────

app = FastAPI(
    title="Studiomc Orchestrator",
    description=(
        "Recursive reasoning orchestrator — plan → tool → observe → answer. "
        "Supports fast, cited, and investigate modes with budget enforcement."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

app.include_router(router)


# ── Direct execution ────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=ORCHESTRATOR_PORT,
        log_level="info",
    )
