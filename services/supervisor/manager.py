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

import httpx

sys.path.insert(0, str(Path(__file__).parent.parent))
from common.config import ALL_BACKEND_PORTS, ALL_PORTS, LOGS_DIR, SERVICE_HOST, ensure_dirs, service_url
from common.hardware import scan_hardware
from common.pro_pack import ProPackRequiredError
from common.pro_pack import get_status as pro_pack_status
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
    "mcp": "mcp/app.py",
    "memory": "memory/app.py",
}

HEALTH_CHECK_INTERVAL = 5  # seconds
MAX_FAIL_BEFORE_RESTART = 3
MAX_RESTARTS = 5
GRACEFUL_SHUTDOWN_TIMEOUT = 5  # seconds before SIGKILL

# After this many seconds of continuous healthy uptime, reset the
# restart counter so transient failures earlier in the day don't push
# the service into a permanent "failed" state.
HEALTHY_RESET_UPTIME = 300  # 5 minutes

# ── Deferred (Pro-pack-only) services ──────────────────────────────────
# Services that depend on the Pro pack are NOT started by ``start_all``.
# They're spawned on demand (Flutter pings ``/services/start?name=training``
# when the user opens the Training screen) and stopped automatically after
# ``IDLE_EVICT_SECONDS`` of no activity, freeing the ~2-3 GB of resident
# RAM PyTorch holds open. The training service is responsible for calling
# ``POST /services/training/touch`` whenever it serves a request.
DEFERRED_SERVICES: set[str] = {"training"}
IDLE_EVICT_SECONDS = 600  # 10 minutes of no /touch → stop the service


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
    # Last activity timestamp for idle eviction (deferred services only).
    # Bumped via ``ProcessManager.touch_service()``. ``None`` means never
    # touched since startup, in which case ``start_time`` is used as the
    # baseline.
    last_activity: float | None = None

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


@dataclass
class StartupState:
    """Where the supervisor is in its own boot sequence.

    ``/health`` answers as soon as uvicorn is serving, which is before any
    child has been spawned; clients that need the children (the desktop
    app, the smoke test) read ``ready`` instead of assuming a 200 means
    the backend is up.
    """

    phase: str = "starting"  # starting | cleaning_ports | launching_services | ready | failed
    ready: bool = False
    error: str | None = None
    started_at: float = field(default_factory=time.time)
    ready_at: float | None = None

    def to_dict(self) -> dict[str, object]:
        return {
            "ready": self.ready,
            "phase": self.phase,
            "startup_error": self.error,
            "uptime_s": round(time.time() - self.started_at, 1),
            "ready_after_s": (
                round(self.ready_at - self.started_at, 1) if self.ready_at else None
            ),
        }


# ── Manager ──────────────────────────────────────────────────────────────


class ProcessManager:
    """Manages the lifecycle of all Studiomc backend services."""

    def __init__(self) -> None:
        ensure_dirs()
        self._services: dict[str, ManagedProcess] = {}
        # Per-service async locks prevent concurrent start/stop/restart
        # from the user-facing API and the background health-check loop
        # from spawning duplicate processes on the same port.
        self._service_locks: dict[str, asyncio.Lock] = {}
        self._health_task: asyncio.Task[None] | None = None
        self._hw_info: HardwareInfo | None = None
        self._shutting_down = False
        self._startup = StartupState()

        for name, rel_path in MANAGED_SERVICES.items():
            port = ALL_PORTS.get(name, 0)
            self._services[name] = ManagedProcess(
                name=name,
                port=port,
                app_path=str(SERVICES_DIR / rel_path),
            )
            self._service_locks[name] = asyncio.Lock()

    # ── Startup state ────────────────────────────────────────────────

    @property
    def startup(self) -> StartupState:
        return self._startup

    def set_startup_phase(self, phase: str, *, ready: bool = False, error: str | None = None) -> None:
        self._startup.phase = phase
        self._startup.ready = ready
        self._startup.error = error
        if ready:
            self._startup.ready_at = time.time()

    # ── Stale process cleanup ────────────────────────────────────────

    def kill_stale_port_holders(self) -> None:
        """Kill leftover Studiomc processes holding our ports from a previous run.

        When the app is quit abruptly, child services (started with setsid)
        can survive and hold ports, and the next launch cannot bind. Only
        processes that are recognisably ours are killed: an unrelated app
        that happens to sit on one of our ports is reported, not shot,
        and the affected service fails to bind with a clear error instead.
        """
        for port in ALL_BACKEND_PORTS:
            if not self._port_in_use(port):
                continue
            holders = self._port_holders(port)
            if not holders:
                logger.warning(
                    "Port %d is in use but no holder could be identified; "
                    "the service on it will fail to bind", port,
                )
                continue
            for pid, cmdline in holders:
                if pid == os.getpid():
                    continue
                if not self._is_studiomc_process(cmdline):
                    logger.error(
                        "Port %d is held by a non-Studiomc process pid=%d (%s); "
                        "not killing it, the service on that port will fail to bind",
                        port, pid, cmdline[:120],
                    )
                    continue
                logger.warning("Port %d held by stale Studiomc process pid=%d; killing it", port, pid)
                self._kill_pid(pid)

    @staticmethod
    def _port_in_use(port: int) -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            return s.connect_ex((SERVICE_HOST, port)) == 0

    # Anything the supervisor, bundle_entry or the sidecar could have been
    # started as. Dev checkouts run ``python <repo>/services/<svc>/app.py``
    # so the services directory itself is a marker too.
    _OWN_CMDLINE_MARKERS: tuple[str, ...] = (
        "studiomc_services",
        "bundle_entry",
        "llama-server",
        str(SERVICES_DIR).lower(),
    )

    @classmethod
    def _is_studiomc_process(cls, cmdline: str) -> bool:
        lowered = cmdline.lower()
        return any(marker in lowered for marker in cls._OWN_CMDLINE_MARKERS)

    @staticmethod
    def _port_holders(port: int) -> list[tuple[int, str]]:
        """Return ``(pid, cmdline)`` for every listener on ``port``.

        psutil's per-process connection listing works without privileges
        for processes we own on every platform (system-wide
        ``net_connections`` needs root on macOS). ``lsof`` is the fallback
        where psutil cannot see the holder.
        """
        holders: dict[int, str] = {}
        try:
            import psutil

            for proc in psutil.process_iter(["pid", "cmdline"]):
                try:
                    conns = proc.net_connections(kind="tcp")
                except (psutil.AccessDenied, psutil.NoSuchProcess, psutil.ZombieProcess):
                    continue
                except Exception:
                    continue
                for conn in conns:
                    if conn.status == psutil.CONN_LISTEN and conn.laddr and conn.laddr.port == port:
                        holders[proc.pid] = " ".join(proc.info.get("cmdline") or []) or proc.name()
                        break
        except Exception as exc:
            logger.debug("psutil port scan failed for %d: %s", port, exc)

        if not holders and sys.platform != "win32":
            try:
                result = subprocess.run(
                    ["lsof", "-ti", f":{port}", "-sTCP:LISTEN"],
                    capture_output=True, text=True, timeout=5,
                )
                for pid_str in result.stdout.split():
                    if not pid_str.isdigit():
                        continue
                    pid = int(pid_str)
                    cmd = subprocess.run(
                        ["ps", "-o", "command=", "-p", str(pid)],
                        capture_output=True, text=True, timeout=5,
                    ).stdout.strip()
                    holders[pid] = cmd
            except Exception as exc:
                logger.debug("lsof port scan failed for %d: %s", port, exc)
        return sorted(holders.items())

    @staticmethod
    def _kill_pid(pid: int) -> None:
        try:
            import psutil

            proc = psutil.Process(pid)
            proc.kill()
            proc.wait(timeout=3)
            logger.info("Killed stale process %d", pid)
            return
        except Exception:
            pass
        if sys.platform != "win32":
            try:
                os.kill(pid, signal.SIGKILL)
                logger.info("Killed stale process %d", pid)
            except (ProcessLookupError, PermissionError):
                pass

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
        """Start every managed service in order.

        Services in :data:`DEFERRED_SERVICES` (e.g. ``training`` which
        needs the ~1 GB Pro pack) are skipped — they're spawned on demand
        via an explicit ``start_service(name)`` call from the UI.
        """
        results: list[ServiceStatus] = []
        for name in MANAGED_SERVICES:
            if name in DEFERRED_SERVICES:
                # Report current status without launching.
                results.append(self._get(name).to_status())
                continue
            if self._shutting_down:
                # /shutdown arrived while we were still booting (startup
                # runs in the background now); do not spawn what stop_all
                # has already passed in its reverse sweep.
                logger.info("Shutdown requested during startup; not launching %s", name)
                results.append(self._get(name).to_status())
                continue
            st = await self.start_service(name)
            results.append(st)
        if not self._shutting_down:
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
        """Start a single service by name (idempotent, lock-protected)."""
        svc = self._get(name)
        async with self._service_locks[name]:
            return await self._start_service_locked(svc)

    async def _start_service_locked(self, svc: ManagedProcess) -> ServiceStatus:
        """Inner implementation. Caller must hold ``_service_locks[svc.name]``."""
        # Re-check status after acquiring the lock — another caller may
        # have already started the service while we were waiting.
        if svc.status in ("running", "starting") and svc.process is not None:
            return svc.to_status()

        if svc.status == "failed":
            svc.restart_count = 0
            svc.consecutive_failures = 0
            svc._backoff = 1.0

        svc.status = "starting"
        svc.error = None

        # An app upgrade replaces the .app while an old supervisor may
        # still be running. Its ``sys.executable`` is now gone and every
        # spawn would raise FileNotFoundError. Fail fast with a message
        # that says what happened, and ask the supervisor to exit so the
        # new app can launch the matching backend.
        if IS_BUNDLED and not Path(sys.executable).exists():
            svc.status = "failed"
            svc.error = (
                f"Bundle executable no longer exists: {sys.executable} "
                "(app was upgraded or removed). Supervisor will exit."
            )
            logger.error("%s: %s", svc.name, svc.error)
            self._request_supervisor_exit()
            return svc.to_status()

        try:
            log_path = LOGS_DIR / f"{svc.name}.log"
            log_file = open(log_path, "a")

            env = os.environ.copy()
            env["PYTHONUNBUFFERED"] = "1"
            # Children run in their own session (setsid below) so a signal
            # to the supervisor's group does not tear them down mid-request.
            # The flip side: if the supervisor is SIGKILLed they would live
            # forever and hold the ports. bundle_entry watches this pid and
            # exits when it disappears.
            env["STUDIOMC_SUPERVISOR_PID"] = str(os.getpid())
            # Pro-pack-routed services (training) are launched with a
            # *separate* Python interpreter living in ``~/.studiomc/pro-env/``.
            # That interpreter doesn't know about the bundled service
            # packages, so we point it at SERVICES_DIR via PYTHONPATH.
            if svc.name in DEFERRED_SERVICES:
                env["PYTHONPATH"] = (
                    str(SERVICES_DIR)
                    + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
                )

            cmd = self._build_launch_cmd(svc)
            logger.info("Launching %s: %s", svc.name, " ".join(cmd))

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
            svc.last_activity = svc.start_time
            svc.status = "running"
            logger.info("Started %s (pid=%s, port=%s)", svc.name, svc.pid, svc.port)
        except ProPackRequiredError as exc:
            # Specific path for deferred services: surface a structured
            # error the supervisor route can convert into HTTP 412 so the
            # Flutter UI knows to pop the install dialog.
            svc.status = "error"
            svc.error = "pro_pack_required"
            logger.warning("Cannot start %s: %s", svc.name, exc)
            raise
        except Exception as exc:
            svc.status = "error"
            svc.error = str(exc)
            logger.exception("Failed to start %s", svc.name)

        self._ensure_health_loop()
        return svc.to_status()

    async def stop_service(self, name: str) -> ServiceStatus:
        """Gracefully stop a single service (lock-protected)."""
        svc = self._get(name)
        async with self._service_locks[name]:
            return await self._stop_service_locked(svc)

    async def _stop_service_locked(self, svc: ManagedProcess) -> ServiceStatus:
        if svc.process is None or svc.status == "stopped":
            svc.status = "stopped"
            return svc.to_status()

        await self._terminate(svc)
        return svc.to_status()

    def touch_service(self, name: str) -> None:
        """Bump the last-activity timestamp for a deferred service.

        Called by deferred services (currently only ``training``) on every
        request so the supervisor doesn't evict them mid-run. No-op for
        services that aren't in :data:`DEFERRED_SERVICES`.
        """
        if name not in DEFERRED_SERVICES:
            return
        svc = self._services.get(name)
        if svc is None:
            return
        svc.last_activity = time.time()

    async def restart_service(self, name: str) -> ServiceStatus:
        """Restart a single service (atomic stop+start under the same lock)."""
        svc = self._get(name)
        async with self._service_locks[name]:
            await self._stop_service_locked(svc)
            await asyncio.sleep(0.5)  # let port release
            return await self._start_service_locked(svc)

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
        await self._evict_idle()

    async def _evict_idle(self) -> None:
        """Stop deferred services that have been idle for too long.

        Frees ~2-3 GB of RAM that PyTorch holds open after a training run
        completes. Triggered solely from the health-check loop so we don't
        need a separate timer.
        """
        now = time.time()
        for name in DEFERRED_SERVICES:
            svc = self._services.get(name)
            if svc is None or svc.status != "running":
                continue
            baseline = svc.last_activity or svc.start_time
            if baseline is None:
                continue
            idle = now - baseline
            if idle < IDLE_EVICT_SECONDS:
                continue
            logger.info(
                "Evicting idle deferred service %s (idle=%.0fs > %ds)",
                svc.name, idle, IDLE_EVICT_SECONDS,
            )
            async with self._service_locks[svc.name]:
                await self._stop_service_locked(svc)

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
                    # Reset the restart counter once a service has been
                    # healthy for HEALTHY_RESET_UPTIME seconds. Otherwise
                    # a long-running service that flakes once an hour
                    # eventually trips MAX_RESTARTS and gets marked
                    # permanently failed.
                    uptime = svc.uptime
                    if (
                        svc.restart_count > 0
                        and uptime is not None
                        and uptime >= HEALTHY_RESET_UPTIME
                    ):
                        logger.info(
                            "%s healthy for %.0fs — resetting restart counter (was %d)",
                            svc.name, uptime, svc.restart_count,
                        )
                        svc.restart_count = 0
                        svc._backoff = 1.0
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
        """Restart a service if it hasn't exceeded the restart limit.

        The full stop/start sequence runs under the per-service lock so
        the health loop and a concurrent manual ``restart_service`` call
        cannot race and spawn two processes on the same port.

        Deferred (Pro-pack) services are never auto-restarted — they're
        on-demand, and an unexpected exit means the user's training run
        finished or crashed; either way the supervisor should leave the
        process down until the UI explicitly asks for it again.
        """
        if svc.name in DEFERRED_SERVICES:
            svc.status = "stopped"
            svc.error = None
            return
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

        async with self._service_locks[svc.name]:
            await self._terminate(svc)
            await asyncio.sleep(0.5)
            await self._start_service_locked(svc)

    # ── Internal helpers ─────────────────────────────────────────────

    @staticmethod
    def _build_launch_cmd(svc: ManagedProcess) -> list[str]:
        """Build the command list to start a child service.

        Three flavours:

        * Pro-pack service (currently just ``training``) — launched with
          the Pro pack venv's interpreter (``~/.studiomc/pro-env/bin/python``)
          running ``training/app.py`` directly. PyTorch + transformers
          + peft import inside that subprocess only, never inside the
          frozen supervisor.

        * Bundled core service — launched as
          ``./studiomc_services --service <name>`` so PyInstaller's
          frozen entry point dispatches to the right uvicorn app.

        * Development core service — ``python inference/app.py``.

        Raises :class:`ProPackRequiredError` when a Pro-pack service is
        requested but the pack is missing or out of date.
        """
        if svc.name in DEFERRED_SERVICES:
            status = pro_pack_status()
            if not status.installed or status.needs_upgrade:
                raise ProPackRequiredError(svc.name)
            assert status.python_path is not None
            # In bundled mode the source for training/app.py is shipped
            # as data and lives at SERVICES_DIR/training/app.py.
            return [status.python_path, svc.app_path]
        if IS_BUNDLED:
            return [sys.executable, "--service", svc.name]
        else:
            return [sys.executable, svc.app_path]

    def _get(self, name: str) -> ManagedProcess:
        svc = self._services.get(name)
        if svc is None:
            raise ValueError(f"Unknown service: {name}")
        return svc

    _exit_requested = False

    def _request_supervisor_exit(self) -> None:
        """Signal our own process once; uvicorn runs the lifespan shutdown."""
        if self._exit_requested or self._shutting_down:
            return
        self._exit_requested = True
        try:
            os.kill(os.getpid(), signal.SIGTERM)
        except OSError:
            logger.exception("Could not signal supervisor to exit")

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
