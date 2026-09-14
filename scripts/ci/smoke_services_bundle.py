#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Launch the frozen services bundle the way the desktop app does and
assert it comes up within the app's real timeouts.

Every "backend not detected" release so far shipped with a green build:
PyInstaller succeeded, the DMG was notarised, and the failure only showed
up when a fresh user double-clicked the app. This script reproduces that
first launch on a CI runner:

1. ``studiomc_services --selftest``: import every Core service inside the
   frozen executable (catches missing hidden imports and Pro-pack leaks).
2. Start the supervisor with a clean, empty ``STUDIOMC_HOME``.
3. Wait for ``GET :8110/health`` within ``--supervisor-timeout`` (mirrors
   ``ProcessLauncher._waitForHealthy`` in the Flutter app).
4. Wait for ``GET :8100/health`` within ``--inference-timeout`` (mirrors
   ``BundledInferenceService._waitForHealth``).
5. Wait until every non-deferred service reports ``running`` and none is
   ``error``/``failed``.
6. Optionally assert the ``llama_server`` backend is online, i.e. the
   sidecar binary was actually shipped and is discoverable.
7. ``POST /shutdown`` and verify the whole process tree exits and frees
   its ports (stale children are what cause ``Errno 48`` next launch).

Only the standard library is used so the script runs with whatever
``python3`` a CI runner has, independent of the services venv.

Usage::

    python3 scripts/ci/smoke_services_bundle.py \
        --bundle services/dist/studiomc_services/studiomc_services \
        --require-llama-server
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

HOST = "127.0.0.1"
SUPERVISOR_PORT = 8110
INFERENCE_PORT = 8100
# Must match ``common.config.ALL_PORTS``; the smoke test fails if any of
# these is already bound so a stale process cannot mask a broken bundle.
ALL_PORTS = list(range(8100, 8111))
DEFERRED_SERVICES = {"training"}

# Defaults mirror the Flutter app so a bundle that passes here also passes
# on a user's machine of similar speed. Bump the Flutter constants and
# these together.
DEFAULT_SUPERVISOR_TIMEOUT = 45.0  # ProcessLauncher._waitForHealthy
DEFAULT_INFERENCE_TIMEOUT = 60.0  # BundledInferenceService._waitForHealth
DEFAULT_SERVICES_TIMEOUT = 60.0
SHUTDOWN_TIMEOUT = 20.0


class SmokeError(RuntimeError):
    pass


def _log(msg: str) -> None:
    print(f"[smoke] {msg}", flush=True)


def _http_json(url: str, *, method: str = "GET", timeout: float = 3.0) -> dict | None:
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return None
            body = resp.read().decode("utf-8", "replace")
            return json.loads(body) if body else {}
    except (urllib.error.URLError, socket.timeout, ConnectionError, json.JSONDecodeError, OSError):
        return None


def _port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex((HOST, port)) == 0


def _wait_for(predicate, timeout: float, interval: float = 0.5) -> float | None:
    """Poll ``predicate`` until truthy; return elapsed seconds or None on timeout."""
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if predicate():
            return time.monotonic() - start
        time.sleep(interval)
    return None


def _default_bundle_path() -> Path:
    exe = "studiomc_services.exe" if os.name == "nt" else "studiomc_services"
    return REPO_ROOT / "services" / "dist" / "studiomc_services" / exe


def _dump_logs(data_dir: Path, proc_output: Path) -> None:
    print("\n────── supervisor stdout/stderr ──────", flush=True)
    if proc_output.exists():
        print(proc_output.read_text(errors="replace")[-8000:], flush=True)
    logs_dir = data_dir / "logs"
    if logs_dir.is_dir():
        for log in sorted(logs_dir.glob("*.log")):
            print(f"\n────── {log.name} ──────", flush=True)
            print(log.read_text(errors="replace")[-4000:], flush=True)


def _terminate_tree(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    try:
        if os.name == "nt":
            proc.terminate()
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            if os.name == "nt":
                proc.kill()
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
        proc.wait(timeout=5)


def run_selftest(bundle: Path, env: dict[str, str]) -> None:
    _log(f"running {bundle.name} --selftest")
    result = subprocess.run(
        [str(bundle), "--selftest"],
        env=env,
        capture_output=True,
        text=True,
        timeout=180,
    )
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SmokeError(f"--selftest exited with {result.returncode}")


def run_launch(
    bundle: Path,
    env: dict[str, str],
    data_dir: Path,
    *,
    supervisor_timeout: float,
    inference_timeout: float,
    services_timeout: float,
    require_llama_server: bool,
) -> dict[str, float]:
    timings: dict[str, float] = {}
    proc_output = data_dir / "smoke-supervisor-output.log"
    out_fh = proc_output.open("w")

    popen_kwargs: dict = {}
    if os.name != "nt":
        popen_kwargs["preexec_fn"] = os.setsid

    _log(f"launching {bundle} with STUDIOMC_HOME={data_dir}")
    t0 = time.monotonic()
    proc = subprocess.Popen(
        [str(bundle)],
        env=env,
        stdout=out_fh,
        stderr=subprocess.STDOUT,
        **popen_kwargs,
    )

    def alive_and(pred):
        def inner():
            if proc.poll() is not None:
                raise SmokeError(
                    f"supervisor exited early with code {proc.returncode}"
                )
            return pred()
        return inner

    try:
        sup_url = f"http://{HOST}:{SUPERVISOR_PORT}/health"
        elapsed = _wait_for(
            alive_and(lambda: (_http_json(sup_url) or {}).get("status") == "ok"),
            supervisor_timeout,
        )
        if elapsed is None:
            raise SmokeError(
                f"supervisor /health not ready within {supervisor_timeout:.0f}s "
                "(ProcessLauncher would report 'supervisor health check timed out')"
            )
        timings["supervisor_health_s"] = round(time.monotonic() - t0, 2)
        _log(f"supervisor healthy after {timings['supervisor_health_s']}s")

        inf_url = f"http://{HOST}:{INFERENCE_PORT}/health"
        elapsed = _wait_for(
            alive_and(lambda: (_http_json(inf_url) or {}).get("status") == "ok"),
            max(0.0, inference_timeout - (time.monotonic() - t0)),
        )
        if elapsed is None:
            raise SmokeError(
                f"inference /health not ready within {inference_timeout:.0f}s of launch "
                "(BundledInferenceService would mark the backend unavailable)"
            )
        timings["inference_health_s"] = round(time.monotonic() - t0, 2)
        _log(f"inference healthy after {timings['inference_health_s']}s")

        status_url = f"http://{HOST}:{SUPERVISOR_PORT}/status"
        last_status: dict = {}

        def all_running() -> bool:
            nonlocal last_status
            data = _http_json(status_url)
            if not data:
                return False
            last_status = data
            bad = [
                s for s in data.get("services", [])
                if s["name"] not in DEFERRED_SERVICES and s["status"] in ("error", "failed")
            ]
            if bad:
                raise SmokeError(
                    "services in error state: "
                    + ", ".join(f"{s['name']} ({s['error']})" for s in bad)
                )
            return all(
                s["status"] == "running"
                for s in data.get("services", [])
                if s["name"] not in DEFERRED_SERVICES
            )

        # The supervisor flips a child to "running" as soon as it spawns,
        # so also require every child's own /health to answer.
        def all_children_healthy() -> bool:
            if not all_running():
                return False
            for s in last_status.get("services", []):
                if s["name"] in DEFERRED_SERVICES:
                    continue
                if (_http_json(f"http://{HOST}:{s['port']}/health") or {}).get("status") != "ok":
                    return False
            return True

        elapsed = _wait_for(alive_and(all_children_healthy), services_timeout)
        if elapsed is None:
            not_ready = [
                f"{s['name']}={s['status']}"
                for s in last_status.get("services", [])
                if s["name"] not in DEFERRED_SERVICES
            ]
            raise SmokeError(
                f"not every Core service healthy within {services_timeout:.0f}s: {not_ready}"
            )
        timings["all_services_healthy_s"] = round(time.monotonic() - t0, 2)
        _log(f"all Core services healthy after {timings['all_services_healthy_s']}s")

        backends = _http_json(f"http://{HOST}:{INFERENCE_PORT}/v1/backends") or {}
        by_name = {b["name"]: b for b in backends.get("backends", [])}
        llama = by_name.get("llama_server")
        if llama is None:
            raise SmokeError("inference did not register the llama_server backend")
        if llama.get("online"):
            _log("llama_server backend online (sidecar binary found)")
        else:
            msg = f"llama_server backend offline: {llama.get('error')}"
            if require_llama_server:
                raise SmokeError(msg)
            _log(f"WARNING {msg}")

        # Spot-check a couple of user-facing endpoints the app hits right
        # after connecting so a router import error is not masked by a
        # healthy /health.
        models = _http_json(f"http://{HOST}:{INFERENCE_PORT}/v1/models")
        if models is None or "data" not in models:
            raise SmokeError("GET /v1/models on inference did not return a model list")
        pro = _http_json(f"http://{HOST}:{SUPERVISOR_PORT}/api/pro-pack/status")
        if pro is None or pro.get("installed") is not False:
            raise SmokeError(
                f"/api/pro-pack/status should report installed=false on a clean data dir, got {pro}"
            )
        _log("pro pack correctly reported as not installed (Core boots without it)")

        # Graceful shutdown must take the whole tree down.
        _log("POST /shutdown")
        _http_json(f"http://{HOST}:{SUPERVISOR_PORT}/shutdown", method="POST", timeout=10)
        try:
            proc.wait(timeout=SHUTDOWN_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise SmokeError(
                f"supervisor still running {SHUTDOWN_TIMEOUT:.0f}s after /shutdown"
            ) from None
        timings["shutdown_s"] = round(time.monotonic() - t0, 2)

        leftover = _wait_for(lambda: not any(_port_in_use(p) for p in ALL_PORTS), 10.0)
        if leftover is None:
            held = [p for p in ALL_PORTS if _port_in_use(p)]
            raise SmokeError(f"ports still held after shutdown: {held}")
        _log("all ports released after shutdown")
        return timings
    except SmokeError:
        out_fh.flush()
        _dump_logs(data_dir, proc_output)
        raise
    finally:
        _terminate_tree(proc)
        out_fh.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bundle", type=Path, default=_default_bundle_path())
    parser.add_argument("--data-dir", type=Path, default=None, help="Clean STUDIOMC_HOME (default: fresh temp dir)")
    parser.add_argument("--supervisor-timeout", type=float, default=DEFAULT_SUPERVISOR_TIMEOUT)
    parser.add_argument("--inference-timeout", type=float, default=DEFAULT_INFERENCE_TIMEOUT)
    parser.add_argument("--services-timeout", type=float, default=DEFAULT_SERVICES_TIMEOUT)
    parser.add_argument(
        "--require-llama-server",
        action="store_true",
        help="Fail if the llama-server sidecar is not discoverable",
    )
    parser.add_argument("--skip-selftest", action="store_true")
    parser.add_argument("--keep-data-dir", action="store_true")
    args = parser.parse_args()

    bundle: Path = args.bundle
    if not bundle.is_file():
        _log(f"bundle executable not found: {bundle}")
        return 2

    busy = [p for p in ALL_PORTS if _port_in_use(p)]
    if busy:
        _log(f"refusing to run: ports already in use {busy} (stale backend?)")
        return 2

    data_dir = args.data_dir or Path(tempfile.mkdtemp(prefix="studiomc-smoke-"))
    data_dir.mkdir(parents=True, exist_ok=True)
    if any(data_dir.iterdir()):
        _log(f"refusing to run: --data-dir {data_dir} is not empty (first launch must be clean)")
        return 2

    env = os.environ.copy()
    env["STUDIOMC_HOME"] = str(data_dir)
    env["PYTHONUNBUFFERED"] = "1"
    # A dev checkout's llama-server must not rescue a bundle that forgot to
    # ship its own copy.
    env.pop("STUDIOMC_LLAMA_SERVER", None)

    try:
        if not args.skip_selftest:
            run_selftest(bundle, env)
        timings = run_launch(
            bundle,
            env,
            data_dir,
            supervisor_timeout=args.supervisor_timeout,
            inference_timeout=args.inference_timeout,
            services_timeout=args.services_timeout,
            require_llama_server=args.require_llama_server,
        )
    except SmokeError as exc:
        _log(f"FAILED: {exc}")
        return 1
    finally:
        if not args.keep_data_dir and args.data_dir is None:
            shutil.rmtree(data_dir, ignore_errors=True)

    _log("PASSED " + json.dumps(timings))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("### Services bundle smoke test\n\n")
            fh.write("| Milestone | Seconds since launch |\n|---|---|\n")
            for key, val in timings.items():
                fh.write(f"| `{key}` | {val} |\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
