"""Supervisor API routes.

Endpoints for managing child services and querying hardware info.
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Query

sys.path.insert(0, str(Path(__file__).parent.parent))
from common.schemas import HardwareInfo, ServiceStatus, SupervisorStatus

from supervisor.manager import ProcessManager

router = APIRouter()

# The manager instance is injected at app startup via `set_manager()`.
_manager: ProcessManager | None = None


def set_manager(mgr: ProcessManager) -> None:
    """Called once from app.py to wire the shared manager instance."""
    global _manager
    _manager = mgr


def _mgr() -> ProcessManager:
    if _manager is None:
        raise HTTPException(status_code=503, detail="Supervisor not initialised yet")
    return _manager


# ── Health ───────────────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "supervisor"}


# ── Service status ───────────────────────────────────────────────────────


@router.get("/status", response_model=SupervisorStatus)
async def status() -> SupervisorStatus:
    """Return the status of every managed service."""
    mgr = _mgr()
    return mgr.get_status()


# ── Start / Stop ─────────────────────────────────────────────────────────


@router.post("/start", response_model=list[ServiceStatus])
async def start_services(
    name: Optional[str] = Query(None, description="Service name, or omit to start all"),
) -> list[ServiceStatus]:
    """Start all services, or a single service by name."""
    mgr = _mgr()
    if name:
        st = await mgr.start_service(name)
        return [st]
    return await mgr.start_all()


@router.post("/stop", response_model=list[ServiceStatus])
async def stop_services(
    name: Optional[str] = Query(None, description="Service name, or omit to stop all"),
) -> list[ServiceStatus]:
    """Stop all services, or a single service by name."""
    mgr = _mgr()
    if name:
        st = await mgr.stop_service(name)
        return [st]
    return await mgr.stop_all()


@router.post("/restart/{service_name}", response_model=ServiceStatus)
async def restart_service(service_name: str) -> ServiceStatus:
    """Restart a specific service."""
    mgr = _mgr()
    try:
        return await mgr.restart_service(service_name)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


# ── Hardware ─────────────────────────────────────────────────────────────


@router.get("/hardware", response_model=HardwareInfo | None)
async def get_hardware() -> HardwareInfo | None:
    """Return cached hardware info (may be None if scan hasn't run yet)."""
    return _mgr().hw_info


@router.post("/hardware/scan", response_model=HardwareInfo)
async def scan_hardware() -> HardwareInfo:
    """Force a fresh hardware scan (including disk benchmark)."""
    return await _mgr().scan_hardware(quick=False)
