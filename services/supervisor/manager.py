# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Process manager — start, stop, monitor, and auto-restart child services.

Each managed service is launched as a subprocess running its own uvicorn server.
The manager performs periodic health checks and automatically restarts crashed
services with exponential backoff.

Production (bundled) mode
-------------------------
When running inside a PyInstaller bundle, ``sys._MEIPASS`` is set and
``sys.executable`` points to the frozen ``studiomc_services`` binary.
Child services are launched via ``sys.executable --service <name>`` instead
of ``python path/to/app.py``.
"""

from __future__ import annotations

import asyncio
import logging
import os
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

sys.path.insert(0, str(Path(__file__).parent.parent))
from common.config import ALL_PORTS, LOGS_DIR, SERVICE_HOST, ensure_dirs, service_url
from common.hardware import scan_hardware
from common.schemas import HardwareInfo, ServiceStatus, SupervisorStatus

logger = logging.getLogger("supervisor.manager")

# ── Runtime mode detection ───────────────────────────────────────────────

IS_BUNDLED: bool = getattr(sys, "_MEIPASS", None) is not None
"""True when running inside a PyInstaller --onedir bundle."""

if IS_BUNDLED:
    # In a frozen bundle _MEIPASS is the extraction directory.
    SERVICES_DIR = Path(sys._MEIPASS)  # type: ignore[attr-defined]
    logger.info("Running in BUNDLED mode (_MEIPASS=%s)", SERVICES_DIR)
else:
    SERVICES_DIR = Path(__file__).parent.parent  # …/services/
    logger.info("Running in DEVELOPMENT mode (services=%s)", SERVICES_DIR)

# Services to manage, in start order.
# key = service name (matches ALL_PORTS), value = relative app.py path from SERVICES_DIR
MANAGED_SERVICES: dict[str, str] = {
    "inference": "inference/app.py",
    "model_manager": "model_manager/app.py",
    "documents": "documents/app.py",
    "clara": "clara/app.py",
    "lre": "lre/app.py",
    "orchestrator": "orchestrator/app.py",
    "training": "training/app.py",
    "data_recipes": "data_recipes/app.py",
}

HEALTH_CHECK_INTERVAL = 5  # seconds
MAX_FAIL_BEFORE_RESTART = 3
MAX_RESTARTS = 5
GRACEFUL_SHUTDOWN_TIMEOUT = 5  # seconds before SIGKILL


# ── Per-service state ────────────────────────────────────────────────────


@dataclass
class ManagedProcess:
    """Runtime bookkeeping for one child service."""

    name: str
    port: int
    app_path: str
    process: asyncio.subprocess.Process | None = None
    pid: int | None = None
    start_time: float | None = None
    status: str = "stopped"  # stopped | starting | running | error | failed
    error: str | None = None
    restart_count: int = 0
    consecutive_failures: int = 0
    _backoff: float = 1.0

    # ── helpers ───────────────────────────────────────────────────────

    @property
    def uptime(self) -> float | None:
        if self.start_time and self.status == "running":
            return time.time() - self.start_time
        return None

    def to_status(self) -> ServiceStatus:
        return ServiceStatus(
            name=self.name,
            port=self.port,
            status=self.status,
            pid=self.pid,
            uptime_seconds=self.uptime,
            error=self.error,
        )


# ── Manager ──────────────────────────────────────────────────────────────


class ProcessManager:
    """Manages the lifecycle of all Studiomc backend services."""

    def __init__(self) -> None:
        ensure_dirs()
        self._services: dict[str, ManagedProcess] = {}
        self._health_task: asyncio.Task[None] | None = None
        self._hw_info: HardwareInfo | None = None
        self._shutting_down = False

        for name, rel_path in MANAGED_SERVICES.items():
            port = ALL_PORTS.get(name, 0)
            self._services[name] = ManagedProcess(
                name=name,
                port=port,
                app_path=str(SERVICES_DIR / rel_path),
            )

    # ── Stale process cleanup ────────────────────────────────────────

    def kill_stale_port_holders(self) -> None:
        """Kill any leftover processes holding our ports from a previous run.

        When the app is quit abruptly, child services (started with setsid)
        can survive and hold ports. This prevents the next launch from binding.
        """
        all_ports = list(ALL_PORTS.values())
        for port in all_ports:
            if not self._port_in_use(port):
                continue
            logger.warning("Port %d already in use — killing stale holder", port)
            self._kill_port_holder(port)

    @staticmethod
    def _port_in_use(port: int) -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            return s.connect_ex((SERVICE_HOST, port)) == 0

    @staticmethod
    def _kill_port_holder(port: int) -> None:
        """Find and kill the process listening on a given port."""
        if sys.platform == "win32":
            return
        try:
            result = subprocess.run(
                ["lsof", "-ti", f":{port}"],
                capture_output=True, text=True, timeout=5,
            )
            pids = result.stdout.strip().split()
            for pid_str in pids:
                try:
                    pid = int(pid_str)
                    if pid == os.getpid():
                        continue
                    os.kill(pid, signal.SIGKILL)
                    logger.info("Killed stale process %d on port %d", pid, port)
                except (ValueError, ProcessLookupError, PermissionError):
                    pass
        except Exception as exc:
            logger.warning("Could not clean port %d: %s", port, exc)

    # ── Public API ────────────────────────────────────────────────────

    @property
    def hw_info(self) -> HardwareInfo | None:
        return self._hw_info

    async def scan_hardware(self, quick: bool = False) -> HardwareInfo:
        """Run hardware scan (blocking, offloaded to thread)."""
        loop = asyncio.get_running_loop()
        self._hw_info = await loop.run_in_executor(None, scan_hardware, quick)
        return self._hw_info

    # ── Start / Stop ─────────────────────────────────────────────────

    async def start_all(self) -> list[ServiceStatus]:
        """Start every managed service in order."""
        results: list[ServiceStatus] = []
        for name in MANAGED_SERVICES:
            st = await self.start_service(name)
            results.append(st)
        # Start background health-check loop
        self._ensure_health_loop()
        return results

    async def stop_all(self) -> list[ServiceStatus]:
        """Gracefully stop every managed service (reverse order)."""
        self._shutting_down = True
        if self._health_task and not self._health_task.done():
            self._health_task.cancel()
            try:
                await self._health_task
            except asyncio.CancelledError:
                pass
            self._health_task = None

        results: list[ServiceStatus] = []
        for name in reversed(list(MANAGED_SERVICES)):
            st = await self.stop_service(name)
            results.append(st)
        self._shutting_down = False
        return results

    async def start_service(self, name: str) -> ServiceStatus:
        """Start a single service by name."""
        svc = self._get(name)
        if svc.status in ("running", "starting"):
            return svc.to_status()

        if svc.status == "failed":
            # Reset restart counter on explicit manual start
            svc.restart_count = 0
            svc.consecutive_failures = 0
            svc._backoff = 1.0

        svc.status = "starting"
        svc.error = None

        try:
            log_path = LOGS_DIR / f"{name}.log"
            log_file = open(log_path, "a")

            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"

            cmd = self._build_launch_cmd(svc)
            logger.info("Launching %s: %s", name, " ".join(cmd))

            svc.process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=log_file,
                stderr=asyncio.subprocess.STDOUT,
                env=env,
                # Use a new process group so we can signal the tree
                preexec_fn=os.setsid if sys.platform != "win32" else None,
            )
            svc.pid = svc.process.pid
            svc.start_time = time.time()
            svc.status = "running"
            logger.info("Started %s (pid=%s, port=%s)", name, svc.pid, svc.port)
        except Exception as exc:
            svc.status = "error"
            svc.error = str(exc)
            logger.exception("Failed to start %s", name)

        self._ensure_health_loop()
        return svc.to_status()

    async def stop_service(self, name: str) -> ServiceStatus:
        """Gracefully stop a single service."""
        svc = self._get(name)
        if svc.process is None or svc.status == "stopped":
            svc.status = "stopped"
            return svc.to_status()

        await self._terminate(svc)
        return svc.to_status()

    async def restart_service(self, name: str) -> ServiceStatus:
        """Restart a single service."""
        await self.stop_service(name)
        # Brief pause to let port release
        await asyncio.sleep(0.5)
        return await self.start_service(name)

    # ── Status ───────────────────────────────────────────────────────

    def get_status(self, name: str | None = None) -> SupervisorStatus | ServiceStatus:
        if name:
            return self._get(name).to_status()
        return SupervisorStatus(
            services=[s.to_status() for s in self._services.values()],
            hw_info=self._hw_info,
        )

    def all_service_statuses(self) -> list[ServiceStatus]:
        return [s.to_status() for s in self._services.values()]

    # ── Health-check loop ────────────────────────────────────────────

    def _ensure_health_loop(self) -> None:
        if self._health_task is None or self._health_task.done():
            self._health_task = asyncio.create_task(self._health_loop())

    async def _health_loop(self) -> None:
        """Periodically health-check all running services."""
        while not self._shutting_down:
            try:
                await asyncio.sleep(HEALTH_CHECK_INTERVAL)
                await self._check_all()
            except asyncio.CancelledError:
                return
            except Exception:
                logger.exception("Health-check loop error")

    async def _check_all(self) -> None:
        """One round of health checks across all services."""
        tasks = [self._check_one(svc) for svc in self._services.values() if svc.status in ("running", "starting")]
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _check_one(self, svc: ManagedProcess) -> None:
        """Health-check a single service."""
        # First check if subprocess is still alive
        if svc.process is not None and svc.process.returncode is not None:
            logger.warning("%s process exited with code %s", svc.name, svc.process.returncode)
            svc.status = "error"
            svc.error = f"Process exited with code {svc.process.returncode}"
            svc.consecutive_failures = MAX_FAIL_BEFORE_RESTART  # trigger restart
            await self._maybe_restart(svc)
            return

        url = service_url(svc.port, "/health")
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                resp = await client.get(url)
                if resp.status_code == 200:
                    svc.consecutive_failures = 0
                    if svc.status == "starting":
                        svc.status = "running"
                    return
        except Exception:
            pass

        # Health check failed
        svc.consecutive_failures += 1
        logger.warning(
            "%s health-check failed (%d/%d)",
            svc.name, svc.consecutive_failures, MAX_FAIL_BEFORE_RESTART,
        )

        if svc.consecutive_failures >= MAX_FAIL_BEFORE_RESTART:
            await self._maybe_restart(svc)

    async def _maybe_restart(self, svc: ManagedProcess) -> None:
        """Restart a service if it hasn't exceeded the restart limit."""
        if svc.restart_count >= MAX_RESTARTS:
            svc.status = "failed"
            svc.error = f"Exceeded max restarts ({MAX_RESTARTS})"
            logger.error("%s marked as FAILED — too many restarts", svc.name)
            return

        svc.restart_count += 1
        backoff = svc._backoff
        svc._backoff = min(svc._backoff * 2, 30.0)

        logger.info("Restarting %s (attempt %d, backoff %.1fs)", svc.name, svc.restart_count, backoff)
        await asyncio.sleep(backoff)

        await self._terminate(svc)
        await asyncio.sleep(0.5)
        await self.start_service(svc.name)

    # ── Internal helpers ─────────────────────────────────────────────

    @staticmethod
    def _build_launch_cmd(svc: ManagedProcess) -> list[str]:
        """Build the command list to start a child service.

        Development mode:
            ["/path/to/.venv/bin/python", "inference/app.py"]

        Bundled mode (PyInstaller):
            ["/path/to/studiomc_services", "--service", "inference"]
        """
        if IS_BUNDLED:
            return [sys.executable, "--service", svc.name]
        else:
            return [sys.executable, svc.app_path]

    def _get(self, name: str) -> ManagedProcess:
        svc = self._services.get(name)
        if svc is None:
            raise ValueError(f"Unknown service: {name}")
        return svc

    async def _terminate(self, svc: ManagedProcess) -> None:
        """Send SIGTERM, wait, then SIGKILL if needed."""
        proc = svc.process
        if proc is None:
            svc.status = "stopped"
            return

        try:
            if sys.platform != "win32":
                # Kill the whole process group
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            else:
                proc.terminate()
        except (ProcessLookupError, OSError):
            pass

        try:
            await asyncio.wait_for(proc.wait(), timeout=GRACEFUL_SHUTDOWN_TIMEOUT)
        except asyncio.TimeoutError:
            logger.warning("%s did not exit in %ds — sending SIGKILL", svc.name, GRACEFUL_SHUTDOWN_TIMEOUT)
            try:
                if sys.platform != "win32":
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                else:
                    proc.kill()
            except (ProcessLookupError, OSError):
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=2)
            except asyncio.TimeoutError:
                pass

        svc.process = None
        svc.pid = None
        svc.start_time = None
        svc.status = "stopped"
        svc.consecutive_failures = 0
        logger.info("%s stopped", svc.name)
