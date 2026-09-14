# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""``llama-server`` sidecar manager.

Owns the lifecycle of the upstream ``llama-server`` binary
(precompiled from `ggerganov/llama.cpp`). One process runs at a time,
serving the currently loaded GGUF model over an OpenAI-compatible HTTP
API (``/v1/chat/completions`` and ``/v1/embeddings``).

Why a separate process?
-----------------------
* ``llama-server`` is a native C++ binary — no Python ML stack needed.
* Crashes or OOMs are isolated from the FastAPI service.
* The binary ships with the Core bundle, so SpliceLLM/PyTorch can stay
  in the optional Pro pack (see ``SPLIT_BUNDLE.md``).

Binary discovery order (first hit wins)
---------------------------------------
1. ``$STUDIOMC_LLAMA_SERVER`` env var (escape hatch for power users).
2. ``$STUDIOMC_HOME/llama-bin/llama-server`` (the install location managed
   by the auto-downloader; persists across app upgrades).
3. ``<bundle>/_internal/bin/llama-server`` inside the frozen PyInstaller
   bundle (``services/bin`` is shipped as data by the spec on every
   platform), with ``Contents/Resources/bin`` kept as a macOS fallback.
4. ``services/bin/llama-server`` (development checkout — populated by
   ``scripts/build/fetch_llama_server.sh``).
5. ``llama-server`` on ``PATH`` (homebrew / system install).

If none of these exist, :meth:`LlamaServerSidecar.binary_path` returns
``None`` and the backend reports ``online=False`` with a clear error so
the UI can prompt the user to download it.
"""

from __future__ import annotations

import asyncio
import logging
import os
import platform
import shutil
import signal
import socket
import sys
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

import httpx

from common.config import LOGS_DIR, ROOT, SERVICE_HOST

logger = logging.getLogger("inference.llama_server")

# ── Configuration ────────────────────────────────────────────────────

# Sidecar listens here; chosen to sit just after the FastAPI inference
# service (8100) and inside the loopback-only range used elsewhere.
LLAMA_SERVER_PORT: int = int(os.environ.get("STUDIOMC_LLAMA_PORT", "8190"))

# How long to wait for /health to come up after spawn.
STARTUP_TIMEOUT_SECONDS: float = 60.0

# How long to wait between health probes during startup.
STARTUP_POLL_INTERVAL: float = 0.25

# Graceful shutdown deadline before SIGKILL.
SHUTDOWN_TIMEOUT_SECONDS: float = 5.0

# Idle timeout: stop the process if no chat/embedding request arrives
# for this long. Keeps RAM free on user laptops.
IDLE_TIMEOUT_SECONDS: float = 5 * 60.0

# Default context length. Modern small GGUF models comfortably handle 8k.
DEFAULT_CONTEXT_LENGTH: int = 8192

# How many GPU layers to offload. ``-1`` (or any large number) = all.
DEFAULT_NGL: int = 999


# ── Binary discovery ──────────────────────────────────────────────────

LLAMA_BIN_DIRNAME = "llama-bin"
LLAMA_BIN_DIR: Path = ROOT / LLAMA_BIN_DIRNAME


def _binary_name() -> str:
    return "llama-server.exe" if os.name == "nt" else "llama-server"


def _candidate_paths() -> list[Path]:
    """Return the discovery order documented in the module docstring."""
    name = _binary_name()
    paths: list[Path] = []

    env_override = os.environ.get("STUDIOMC_LLAMA_SERVER")
    if env_override:
        paths.append(Path(env_override).expanduser())

    paths.append(LLAMA_BIN_DIR / name)

    # PyInstaller-bundled locations. The spec ships ``services/bin`` as
    # data, which PyInstaller >= 6 unpacks under ``_internal/`` (exposed
    # as ``sys._MEIPASS``), not next to the executable. Older layouts and
    # the macOS ``Contents/Resources/bin`` embed are kept as fallbacks.
    if getattr(sys, "frozen", False):
        meipass = getattr(sys, "_MEIPASS", None)
        if meipass:
            paths.append(Path(meipass) / "bin" / name)
        exe_dir = Path(sys.executable).resolve().parent
        paths.append(exe_dir / "bin" / name)
        paths.append(exe_dir / "_internal" / "bin" / name)
        # …/Contents/Resources/studiomc_services/studiomc_services →
        # …/Contents/Resources/bin/llama-server
        paths.append(exe_dir.parent / "bin" / name)

    # Development checkout — services/bin/<name>
    repo_bin = Path(__file__).resolve().parent.parent / "bin" / name
    paths.append(repo_bin)

    on_path = shutil.which(name)
    if on_path:
        paths.append(Path(on_path))

    return paths


def find_llama_server_binary() -> Path | None:
    """Locate the llama-server binary, or return ``None`` if missing."""
    for p in _candidate_paths():
        try:
            if p.is_file() and os.access(p, os.X_OK):
                return p
        except OSError:
            continue
    return None


def detect_platform() -> str:
    """Return a short platform tag used by the auto-downloader."""
    system = platform.system().lower()
    machine = platform.machine().lower()

    if system == "darwin":
        return "macos-arm64" if machine in ("arm64", "aarch64") else "macos-x64"
    if system == "linux":
        return "linux-arm64" if machine in ("arm64", "aarch64") else "linux-x64"
    if system == "windows":
        return "windows-x64"
    return f"{system}-{machine}"


# ── Sidecar lifecycle ────────────────────────────────────────────────

class LlamaServerError(RuntimeError):
    """Raised for unrecoverable sidecar failures (binary missing, crash, …)."""


class LlamaServerSidecar:
    """Owns one ``llama-server`` child process.

    Concurrency model
    -----------------
    All public coroutines are serialised by :attr:`_lock`. The chat /
    embedding HTTP endpoints are reentrant (llama-server itself handles
    request queueing), so once :meth:`ensure_loaded` returns the caller
    can fire as many parallel ``httpx`` requests as it wants.

    Idle eviction
    -------------
    Each successful HTTP call calls :meth:`touch`. A background watchdog
    spawned in :meth:`start` checks every 30 s and unloads the model if
    ``IDLE_TIMEOUT_SECONDS`` has elapsed since the last touch.
    """

    def __init__(
        self,
        *,
        port: int = LLAMA_SERVER_PORT,
        host: str = SERVICE_HOST,
        context_length: int = DEFAULT_CONTEXT_LENGTH,
        ngl: int = DEFAULT_NGL,
        idle_timeout: float = IDLE_TIMEOUT_SECONDS,
    ) -> None:
        self._port = port
        self._host = host
        self._context_length = context_length
        self._ngl = ngl
        self._idle_timeout = idle_timeout

        self._process: asyncio.subprocess.Process | None = None
        self._loaded_model_path: Path | None = None
        self._loaded_at: float | None = None
        self._last_used: float = 0.0
        self._log_file: object | None = None  # file handle (kept open)

        self._lock = asyncio.Lock()
        self._watchdog: asyncio.Task[None] | None = None
        self._stopping = False

    # ── Public properties ────────────────────────────────────────────

    @property
    def base_url(self) -> str:
        return f"http://{self._host}:{self._port}"

    @property
    def is_running(self) -> bool:
        return self._process is not None and self._process.returncode is None

    @property
    def loaded_model_path(self) -> Path | None:
        return self._loaded_model_path if self.is_running else None

    @property
    def binary_path(self) -> Path | None:
        return find_llama_server_binary()

    # ── Lifecycle ────────────────────────────────────────────────────

    async def ensure_loaded(self, model_path: Path) -> None:
        """Make sure the sidecar is running with the requested GGUF.

        If a different model is currently loaded, the old process is
        stopped and a new one is spawned. The call blocks until the
        sidecar's ``/health`` endpoint reports ready.
        """
        async with self._lock:
            if self.is_running and self._loaded_model_path == model_path:
                self.touch()
                return

            await self._stop_locked()
            await self._start_locked(model_path)

    async def stop(self) -> None:
        """Shut the sidecar down (used by supervisor on app exit)."""
        async with self._lock:
            self._stopping = True
            await self._stop_locked()
            self._stopping = False

    def touch(self) -> None:
        """Mark the sidecar as recently used (resets the idle watchdog)."""
        self._last_used = time.monotonic()

    # ── Internal: start ───────────────────────────────────────────────

    async def _start_locked(self, model_path: Path) -> None:
        binary = self.binary_path
        if binary is None:
            raise LlamaServerError(
                "llama-server binary not found. Looked in: "
                + ", ".join(str(p) for p in _candidate_paths())
            )
        if not model_path.is_file():
            raise LlamaServerError(f"GGUF model not found: {model_path}")

        # Make sure nobody else is on our port (e.g. a stale child from
        # a previous crash). If so, kill it before spawning.
        if _port_in_use(self._host, self._port):
            logger.warning(
                "llama-server port %d busy at startup — killing stale holder",
                self._port,
            )
            _kill_port_holder(self._port)
            await asyncio.sleep(0.25)

        cmd = [
            str(binary),
            "--model", str(model_path),
            "--host", self._host,
            "--port", str(self._port),
            "--ctx-size", str(self._context_length),
            "--n-gpu-layers", str(self._ngl),
            # Bind embeddings + chat on the same server. Slightly more
            # memory but avoids running two processes.
            "--embeddings",
            # Quieter than default; we capture stdout+stderr to a log file.
            "--log-disable",
        ]
        logger.info("Spawning llama-server: %s", " ".join(cmd))

        LOGS_DIR.mkdir(parents=True, exist_ok=True)
        log_path = LOGS_DIR / "llama-server.log"
        self._log_file = open(log_path, "a", buffering=1, encoding="utf-8")
        self._log_file.write(  # type: ignore[attr-defined]
            f"\n──── llama-server start {time.strftime('%Y-%m-%d %H:%M:%S')} ────\n"
            f"model: {model_path}\n"
        )

        try:
            self._process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=self._log_file,
                stderr=asyncio.subprocess.STDOUT,
                # New process group on POSIX so we can SIGTERM the whole tree.
                preexec_fn=os.setsid if sys.platform != "win32" else None,
            )
        except FileNotFoundError as exc:
            raise LlamaServerError(f"Failed to spawn llama-server: {exc}") from exc

        try:
            await self._wait_for_ready()
        except Exception:
            await self._stop_locked()
            raise

        self._loaded_model_path = model_path
        self._loaded_at = time.monotonic()
        self.touch()
        logger.info(
            "llama-server ready (pid=%s, model=%s, port=%d)",
            self._process.pid if self._process else "?",
            model_path.name,
            self._port,
        )

        if self._watchdog is None or self._watchdog.done():
            self._watchdog = asyncio.create_task(self._idle_watchdog())

    async def _wait_for_ready(self) -> None:
        """Poll ``/health`` until the server reports ready."""
        deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
        url = f"{self.base_url}/health"
        last_error: str | None = None

        async with httpx.AsyncClient(timeout=2.0) as client:
            while time.monotonic() < deadline:
                if self._process is None or self._process.returncode is not None:
                    raise LlamaServerError(
                        f"llama-server exited during startup "
                        f"(code={self._process.returncode if self._process else 'n/a'}). "
                        f"See {LOGS_DIR / 'llama-server.log'} for details."
                    )
                try:
                    resp = await client.get(url)
                    if resp.status_code == 200:
                        return
                    last_error = f"HTTP {resp.status_code}"
                except httpx.HTTPError as exc:
                    last_error = str(exc) or exc.__class__.__name__
                await asyncio.sleep(STARTUP_POLL_INTERVAL)

        raise LlamaServerError(
            f"llama-server failed to become ready within "
            f"{STARTUP_TIMEOUT_SECONDS:.0f}s: {last_error or 'no response'}"
        )

    # ── Internal: stop ───────────────────────────────────────────────

    async def _stop_locked(self) -> None:
        proc = self._process
        if proc is None:
            self._reset_state()
            return

        if proc.returncode is None:
            try:
                if sys.platform != "win32":
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                else:
                    proc.terminate()
            except (ProcessLookupError, OSError):
                pass

            try:
                await asyncio.wait_for(proc.wait(), timeout=SHUTDOWN_TIMEOUT_SECONDS)
            except asyncio.TimeoutError:
                logger.warning("llama-server did not exit; sending SIGKILL")
                try:
                    if sys.platform != "win32":
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    else:
                        proc.kill()
                except (ProcessLookupError, OSError):
                    pass
                try:
                    await asyncio.wait_for(proc.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    pass

        self._reset_state()

    def _reset_state(self) -> None:
        self._process = None
        self._loaded_model_path = None
        self._loaded_at = None
        if self._log_file is not None:
            try:
                self._log_file.close()  # type: ignore[attr-defined]
            except Exception:
                pass
            self._log_file = None

    # ── Idle eviction ────────────────────────────────────────────────

    async def _idle_watchdog(self) -> None:
        """Background task: stop the sidecar after ``idle_timeout`` of silence."""
        try:
            while True:
                await asyncio.sleep(30.0)
                if self._stopping or not self.is_running:
                    return
                if (time.monotonic() - self._last_used) >= self._idle_timeout:
                    logger.info(
                        "llama-server idle for %.0fs — stopping to free RAM",
                        self._idle_timeout,
                    )
                    await self.stop()
                    return
        except asyncio.CancelledError:
            return
        except Exception:
            logger.exception("llama-server watchdog crashed")

    # ── HTTP convenience ─────────────────────────────────────────────

    @asynccontextmanager
    async def http(self, *, timeout: float = 600.0) -> AsyncIterator[httpx.AsyncClient]:
        """Yield a configured ``httpx.AsyncClient`` pointed at the sidecar.

        Touches the idle clock on context entry so streaming requests
        that take longer than the timeout still keep the server alive.
        """
        if not self.is_running:
            raise LlamaServerError("llama-server is not running")
        self.touch()
        async with httpx.AsyncClient(base_url=self.base_url, timeout=timeout) as client:
            yield client


# ── Port helpers (mirror supervisor/manager.py) ──────────────────────

def _port_in_use(host: str, port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.25)
        return s.connect_ex((host, port)) == 0


def _kill_port_holder(port: int) -> None:
    if sys.platform == "win32":
        return
    try:
        import subprocess
        out = subprocess.run(
            ["lsof", "-ti", f":{port}"],
            capture_output=True, text=True, timeout=5,
        )
        for pid_str in out.stdout.strip().split():
            try:
                pid = int(pid_str)
                if pid == os.getpid():
                    continue
                os.kill(pid, signal.SIGKILL)
            except (ValueError, ProcessLookupError, PermissionError):
                pass
    except Exception as exc:
        logger.warning("Could not free port %d: %s", port, exc)


# ── Process-wide singleton ───────────────────────────────────────────

_sidecar_singleton: LlamaServerSidecar | None = None
_singleton_lock = asyncio.Lock()


async def get_sidecar() -> LlamaServerSidecar:
    """Return the process-wide ``LlamaServerSidecar`` instance.

    Created lazily so importing this module is free.
    """
    global _sidecar_singleton
    async with _singleton_lock:
        if _sidecar_singleton is None:
            _sidecar_singleton = LlamaServerSidecar()
        return _sidecar_singleton


def get_sidecar_sync() -> LlamaServerSidecar:
    """Sync accessor — only use during module init / shutdown hooks."""
    global _sidecar_singleton
    if _sidecar_singleton is None:
        _sidecar_singleton = LlamaServerSidecar()
    return _sidecar_singleton
