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

import hashlib

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from common.config import INFERENCE_PORT, SERVICE_HOST, ensure_dirs
from common.database import Database

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

    logger.info("Listening on %s:%d", SERVICE_HOST, INFERENCE_PORT)

    yield

    logger.info("Inference Service shutting down")
    await inference_router.close()


# ── Auth Middleware ────────────────────────────────────────────────────

# Paths that never require auth (health, WebSocket from local Flutter app)
_PUBLIC_PATHS = {"/health", "/v1/chat/stream"}


class ApiKeyAuthMiddleware(BaseHTTPMiddleware):
    """Bearer-token auth for external tool access (Cursor, Claude Code, etc.).

    Rules:
    - Requests WITHOUT an Authorization header are allowed (local Flutter app).
    - Requests WITH ``Authorization: Bearer sk-studiomc-...`` are verified
      against the api_keys table.
    - Health and WebSocket endpoints are always open.
    """

    async def dispatch(self, request: Request, call_next):
        auth_header = request.headers.get("authorization", "")

        # No auth header → local Flutter / browser request — pass through
        if not auth_header:
            return await call_next(request)

        # Public endpoints
        if request.url.path in _PUBLIC_PATHS:
            return await call_next(request)

        # Bearer token present → validate
        if auth_header.startswith("Bearer "):
            token = auth_header[7:].strip()
            if token:
                try:
                    db = await Database.instance()
                    key_hash = hashlib.sha256(token.encode()).hexdigest()
                    row = await db.fetchone(
                        "SELECT id, revoked FROM api_keys WHERE key_hash = ?",
                        (key_hash,),
                    )
                    if row and not row["revoked"]:
                        # Valid key — update last_used_at and continue
                        await db.execute(
                            "UPDATE api_keys SET last_used_at = datetime('now') WHERE id = ?",
                            (row["id"],),
                        )
                        await db.commit()
                        return await call_next(request)
                except Exception:
                    logger.exception("API key verification error")

            return JSONResponse(
                status_code=401,
                content={"error": {"message": "Invalid or revoked API key", "type": "auth_error"}},
            )

        return await call_next(request)


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

# API key auth for external tools (Cursor, Claude Code, etc.)
app.add_middleware(ApiKeyAuthMiddleware)

# Mount routes
app.include_router(router)


# ── Direct execution ──────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=INFERENCE_PORT,
        reload=False,
        log_level="info",
    )
