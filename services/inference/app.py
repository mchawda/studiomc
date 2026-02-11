# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Inference Service — FastAPI application entry point.

Wraps the Inference Router for multi-backend model inference with:
    - OpenAI-compatible REST API (streaming + non-streaming)
    - WebSocket streaming for Flutter UI
    - Backend discovery (Ollama, LM Studio, SpliceLLM, Frontier APIs)
    - Model management (list, select, route)
    - Performance metrics (tok/s, TTFT)

Run:
    uvicorn services.inference.app:app --host 127.0.0.1 --port 8100
    # or directly:
    python -m services.inference.app
"""

from __future__ import annotations

import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

# ── Path setup so `from common.xxx import ...` works ─────────────────
# Add the services/ directory to sys.path for sibling-package imports.
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from common.config import INFERENCE_PORT, ensure_dirs

from inference.engine import InferenceEngine
from inference.router import InferenceRouter
from inference.routes import router, set_router

# ── Logging ───────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(name)-24s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("inference.app")

# ── Engine + Router singletons ────────────────────────────────────────

engine = InferenceEngine()
inference_router = InferenceRouter(engine)


# ── Lifespan ──────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup / shutdown lifecycle."""
    ensure_dirs()

    # Wire the router into the routes module
    set_router(inference_router)

    logger.info("Inference Service starting (engine: SpliceLLM)")

    # Auto-probe backends on startup
    logger.info("Probing backends...")
    backend_status = await inference_router.probe_backends()
    for name, info in backend_status.items():
        status = "ONLINE" if info.online else "offline"
        model_count = len(info.models)
        extra = f" ({model_count} models)" if info.online and model_count else ""
        logger.info("  %-20s %s%s", name, status, extra)

    logger.info("Listening on 127.0.0.1:%d", INFERENCE_PORT)

    yield

    logger.info("Inference Service shutting down")
    await inference_router.close()


# ── FastAPI app ───────────────────────────────────────────────────────

app = FastAPI(
    title="Studiomc Inference Service",
    description=(
        "Multi-backend LLM inference router with OpenAI-compatible APIs. "
        "Auto-detects Ollama, LM Studio, and built-in SpliceLLM engine."
    ),
    version="0.3.0",
    lifespan=lifespan,
)

# CORS — allow localhost origins for the desktop app
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:*",
        "http://127.0.0.1:*",
        "app://studiomc",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount routes
app.include_router(router)


# ── Direct execution ──────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=INFERENCE_PORT,
        reload=False,
        log_level="info",
    )
