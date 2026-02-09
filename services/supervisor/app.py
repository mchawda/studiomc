"""Studiomc Supervisor — FastAPI application.

The supervisor is the single entry-point that the Flutter desktop app launches.
It starts, monitors, health-checks, and auto-restarts every other backend service.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# ── Path fixup (must come before local imports) ──────────────────────────
sys.path.insert(0, str(Path(__file__).parent.parent))

from common.config import LOGS_DIR, SUPERVISOR_PORT, ensure_dirs

from supervisor.manager import ProcessManager
from supervisor.routes import router, set_manager

# ── Logging ──────────────────────────────────────────────────────────────

ensure_dirs()
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOGS_DIR / "supervisor.log"),
    ],
)
logger = logging.getLogger("supervisor")

# ── Shared manager instance ──────────────────────────────────────────────

manager = ProcessManager()

# ── Lifespan ─────────────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: scan hardware + launch all services. Shutdown: stop all."""
    logger.info("Supervisor starting — scanning hardware…")
    # Full hardware scan (with disk benchmark) on first boot
    try:
        hw = await manager.scan_hardware(quick=False)
        logger.info("Hardware: %s (%s, VRAM %s)", hw.cpu_name, hw.gpu_name, hw.vram_bytes)
    except Exception:
        logger.exception("Hardware scan failed (non-fatal)")

    logger.info("Starting managed services…")
    statuses = await manager.start_all()
    for st in statuses:
        logger.info("  %s → %s (pid=%s)", st.name, st.status, st.pid)

    yield  # ← app is running

    logger.info("Supervisor shutting down — stopping all services…")
    await manager.stop_all()
    logger.info("All services stopped. Goodbye.")


# ── FastAPI app ──────────────────────────────────────────────────────────

app = FastAPI(
    title="Studiomc Supervisor",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Wire the manager into the routes module
set_manager(manager)
app.include_router(router)


# ── Direct execution ─────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=SUPERVISOR_PORT,
        reload=False,
        log_level="info",
    )
