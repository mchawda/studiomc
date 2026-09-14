# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc Supervisor — FastAPI application.

The supervisor is the single entry-point that the Flutter desktop app launches.
It starts, monitors, health-checks, and auto-restarts every other backend service.

Startup ordering matters for the desktop app's first-launch experience:

1. Kill stale port holders from a previous crash.
2. Spawn the managed services (fast: fork + exec only).
3. Return from lifespan so ``/health`` answers immediately.
4. Run the full hardware scan (disk benchmark included) in the background.
5. Watch the parent process (the Flutter app) and shut everything down
   when it exits, so no orphaned backend survives a Cmd+Q.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import sys
from collections.abc import Coroutine
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# ── Path fixup (must come before local imports) ──────────────────────────
sys.path.insert(0, str(Path(__file__).parent.parent))

from common.config import LOGS_DIR, SERVICE_HOST, SUPERVISOR_PORT, ensure_dirs
from common.fastapi_pro_pack import install_pro_pack_handler
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

# The desktop app passes its own PID so we can exit when it does. Absent
# in development (``python supervisor/app.py`` from a terminal), where the
# supervisor must outlive whatever shell started it.
PARENT_PID_ENV = "STUDIOMC_PARENT_PID"
PARENT_POLL_SECONDS = 2.0

# ── Shared manager instance ──────────────────────────────────────────────

manager = ProcessManager()

_background_tasks: set[asyncio.Task[None]] = set()


def _spawn(coro: Coroutine[Any, Any, None]) -> None:
    task = asyncio.create_task(coro)
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)


def _parent_pid() -> int | None:
    raw = os.environ.get(PARENT_PID_ENV, "").strip()
    if not raw:
        return None
    try:
        pid = int(raw)
    except ValueError:
        logger.warning("Ignoring non-numeric %s=%r", PARENT_PID_ENV, raw)
        return None
    return pid if pid > 0 else None


def _pid_alive(pid: int) -> bool:
    try:
        import psutil

        return psutil.pid_exists(pid) and psutil.Process(pid).status() != psutil.STATUS_ZOMBIE
    except Exception:
        # Fallback without psutil (POSIX only): signal 0 probes existence.
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True


def request_self_shutdown(reason: str) -> None:
    """Ask uvicorn to exit cleanly (runs the lifespan shutdown hook)."""
    logger.warning("Supervisor exiting: %s", reason)
    os.kill(os.getpid(), signal.SIGTERM)


async def _background_hardware_scan() -> None:
    logger.info("Scanning hardware in background…")
    try:
        hw = await manager.scan_hardware(quick=False)
        logger.info("Hardware: %s (%s, VRAM %s)", hw.cpu_name, hw.gpu_name, hw.vram_bytes)
    except Exception:
        logger.exception("Hardware scan failed (non-fatal)")


async def _watch_parent(parent_pid: int) -> None:
    logger.info("Watching parent process pid=%d", parent_pid)
    try:
        while True:
            await asyncio.sleep(PARENT_POLL_SECONDS)
            if not _pid_alive(parent_pid):
                request_self_shutdown(f"parent process {parent_pid} is gone")
                return
    except asyncio.CancelledError:
        return


async def _watch_own_executable() -> None:
    """Exit if our bundle was deleted or replaced by an app upgrade.

    ``sys.executable`` is what the manager uses to spawn child services.
    Once it is gone every restart fails with ``FileNotFoundError`` and the
    app is left talking to a zombie backend. Exiting lets the (new) app
    launch the (new) supervisor.
    """
    exe = Path(sys.executable)
    if getattr(sys, "_MEIPASS", None) is None:
        return  # development interpreter, nothing to watch
    try:
        while True:
            await asyncio.sleep(5.0)
            if not exe.exists():
                request_self_shutdown(f"bundle executable vanished: {exe}")
                return
    except asyncio.CancelledError:
        return


# ── Lifespan ─────────────────────────────────────────────────────────────


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup: launch services, then scan hardware in background. Shutdown: stop all."""
    logger.info("Supervisor starting — cleaning up stale processes…")
    manager.kill_stale_port_holders()

    logger.info("Starting managed services…")
    statuses = await manager.start_all()
    for st in statuses:
        logger.info("  %s → %s (pid=%s)", st.name, st.status, st.pid)

    _spawn(_background_hardware_scan())
    _spawn(_watch_own_executable())
    parent = _parent_pid()
    if parent is not None:
        _spawn(_watch_parent(parent))

    yield  # ← app is running

    logger.info("Supervisor shutting down — stopping all services…")
    for task in list(_background_tasks):
        task.cancel()
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
install_pro_pack_handler(app)
app.include_router(router)


# ── Direct execution ─────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=SUPERVISOR_PORT,
        reload=False,
        log_level="info",
    )
