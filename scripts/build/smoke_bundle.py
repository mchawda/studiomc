#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Fresh-install smoke test for the frozen ``studiomc_services`` bundle.

Every "backend not connecting in production" release of Studiomc had the
same shape: a module that imported fine in the dev venv failed inside the
PyInstaller bundle, the child service died on startup, and nobody noticed
until a user installed the DMG. This script is the guard. It runs on the
build machine, against the artefact that will ship, with a clean data
directory, and exercises exactly what a brand-new user's first launch does:

0. ``studiomc_services --selftest``: import every Core service inside the
   frozen executable and fail if a Pro-only library leaked in.
1. Launch the supervisor from the bundle (``STUDIOMC_HOME`` = temp dir).
2. ``GET /health`` on the supervisor within the desktop app's timeout and
   verify it identifies itself as *this* bundle.
3. Wait until the supervisor reports ``ready`` and every managed
   (non-deferred) service is ``running`` and answers ``GET /health``.
4. Inference: the built-in ``llama_server`` backend must report online
   (binary found inside the bundle).
5. Model manager: hardware scan + Autopilot recommendation must return a
   model.
6. Optional ``--gguf PATH``: copy a small GGUF into the fresh models dir,
   select it, and run a real chat completion through llama-server.
7. Optional ``--download REPO``: exercise the HuggingFace download path
   (proves the downloader works without ``huggingface_hub``).
8. ``POST /shutdown`` and assert the supervisor, every child, and the
   llama-server sidecar exit and release their ports.

Only the standard library is used so it runs with any Python 3.11+.

Usage::

    python scripts/build/smoke_bundle.py --bundle services/dist/studiomc_services
    python scripts/build/smoke_bundle.py --app studiomc_app/build/macos/Build/Products/Release/Studiomc.app
    python scripts/build/smoke_bundle.py --bundle … --gguf ~/models/tiny.gguf --download bartowski/Llama-3.2-1B-Instruct-GGUF
    python scripts/build/smoke_bundle.py --app … --download bartowski/Llama-3.2-1B-Instruct-GGUF \\
        --download-complete --download-wait 1800      # full new-user path: download, load, first chat
"""

from __future__ import annotations

import argparse
import json
import os
import platform
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

HOST = "127.0.0.1"
SUPERVISOR_PORT = 8110
INFERENCE_PORT = 8100
MODEL_MANAGER_PORT = 8101
LLAMA_SERVER_PORT = 8190
ALL_PORTS = list(range(8100, 8111)) + [LLAMA_SERVER_PORT]

# Tighter than ProcessLauncher.supervisorStartupTimeout (90 s): the app's
# budget absorbs Gatekeeper's first-launch scan of a quarantined bundle,
# which never happens on a build machine. If the bundle cannot answer
# /health in 45 s here, real users see "backend not detected".
SUPERVISOR_HEALTH_TIMEOUT = 45.0
SERVICES_READY_TIMEOUT = 90.0
SHUTDOWN_TIMEOUT = 30.0


class SmokeFailure(Exception):
    pass


# ── Helpers ──────────────────────────────────────────────────────────────


def log(msg: str) -> None:
    print(f"[smoke] {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"[smoke] ✓ {msg}", flush=True)


def http(method: str, url: str, body: dict | None = None, timeout: float = 10.0) -> tuple[int, object]:
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            try:
                return resp.status, json.loads(raw) if raw else None
            except json.JSONDecodeError:
                return resp.status, raw.decode(errors="replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            return exc.code, json.loads(raw) if raw else None
        except json.JSONDecodeError:
            return exc.code, raw.decode(errors="replace")


def try_http(method: str, url: str, body: dict | None = None, timeout: float = 5.0) -> tuple[int, object] | None:
    try:
        return http(method, url, body, timeout)
    except (urllib.error.URLError, ConnectionError, socket.timeout, OSError):
        return None


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.3)
        return s.connect_ex((HOST, port)) == 0


def pids_on_port(port: int) -> list[int]:
    if platform.system() == "Windows":
        return []
    try:
        out = subprocess.run(["lsof", "-ti", f":{port}"], capture_output=True, text=True, timeout=5)
        return [int(p) for p in out.stdout.split() if p.strip().isdigit()]
    except Exception:
        return []


def wait_until(pred, timeout: float, interval: float = 0.5, what: str = "") -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if pred():
            return True
        time.sleep(interval)
    return False


def exe_name() -> str:
    return "studiomc_services.exe" if platform.system() == "Windows" else "studiomc_services"


def resolve_bundle(args: argparse.Namespace) -> Path:
    if args.app:
        app = Path(args.app).expanduser().resolve()
        if platform.system() == "Darwin":
            bundle = app / "Contents" / "Resources" / "studiomc_services"
        else:
            bundle = app / "studiomc_services"
    else:
        bundle = Path(args.bundle).expanduser().resolve()
        # Accept either the dist directory or the executable inside it.
        if bundle.is_file():
            bundle = bundle.parent
    exe = bundle / exe_name()
    if not exe.is_file():
        raise SmokeFailure(f"bundle executable not found: {exe}")
    if platform.system() != "Windows" and not os.access(exe, os.X_OK):
        raise SmokeFailure(f"bundle executable is not executable: {exe}")
    return bundle


# ── Steps ────────────────────────────────────────────────────────────────


def preflight(force: bool) -> None:
    busy = [p for p in ALL_PORTS if port_in_use(p)]
    if busy and not force:
        raise SmokeFailure(
            f"ports already in use: {busy}. Quit Studiomc / dev services first "
            "(the supervisor would SIGKILL whatever holds them). Use --force to proceed."
        )
    if busy:
        log(f"--force: ports {busy} are busy, supervisor will reclaim them")


def fresh_env(home: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["STUDIOMC_HOME"] = str(home)
    env["STUDIOMC_PARENT_PID"] = str(os.getpid())
    env["PYTHONUNBUFFERED"] = "1"
    # Simulate a double-clicked app: no dev venv, no repo on PATH.
    env.pop("VIRTUAL_ENV", None)
    env.pop("PYTHONPATH", None)
    return env


def run_selftest(bundle: Path, home: Path) -> None:
    """Import every Core service inside the frozen executable.

    PyInstaller only warns about modules it cannot trace and its excludes
    list silently drops packages, so a lost hidden import ships as a green
    build and dies as ``Cannot import <svc>.app`` on the user's machine.
    """
    exe = bundle / exe_name()
    t0 = time.monotonic()
    result = subprocess.run(
        [str(exe), "--selftest"],
        env=fresh_env(home),
        cwd=str(home),
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        combined = f"{result.stdout}\n{result.stderr}"
        fail_modules = [
            line.split("FAIL", 1)[1].strip()
            for line in combined.splitlines()
            if "[selftest] FAIL" in line
        ]
        hint = ""
        if "page-aligned" in combined or "libscipy_openblas" in combined:
            hint = (
                " (PyInstaller strip corrupted numpy OpenBLAS on Linux; "
                "studiomc_services.spec must set strip=False off macOS)"
            )
        detail = f": {', '.join(fail_modules[:3])}" if fail_modules else ""
        raise SmokeFailure(f"--selftest exited with {result.returncode}{detail}{hint}")
    imported = sum(1 for line in result.stdout.splitlines() if line.startswith("[selftest] ok"))
    ok(f"--selftest passed inside the frozen bundle in {time.monotonic() - t0:.1f}s ({imported} checks)")


def launch_supervisor(bundle: Path, home: Path, log_path: Path) -> subprocess.Popen:
    exe = bundle / exe_name()
    env = fresh_env(home)
    log(f"launching {exe}")
    log(f"STUDIOMC_HOME={home}")
    out = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen(
        [str(exe)],
        stdout=out,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=str(home),  # NOT the repo: catches relative-path assumptions
    )
    return proc


def check_supervisor_health(proc: subprocess.Popen, bundle: Path) -> dict:
    t0 = time.monotonic()
    result: dict | None = None

    def probe() -> bool:
        nonlocal result
        if proc.poll() is not None:
            raise SmokeFailure(f"supervisor exited early with code {proc.returncode}")
        r = try_http("GET", f"http://{HOST}:{SUPERVISOR_PORT}/health", timeout=3)
        if r and r[0] == 200 and isinstance(r[1], dict):
            result = r[1]
            return True
        return False

    if not wait_until(probe, SUPERVISOR_HEALTH_TIMEOUT):
        raise SmokeFailure(f"supervisor /health not 200 within {SUPERVISOR_HEALTH_TIMEOUT:.0f}s")
    assert result is not None
    elapsed = time.monotonic() - t0
    ok(f"supervisor /health 200 after {elapsed:.1f}s: version={result.get('version')} sha={result.get('git_sha')}")

    if result.get("status") != "ok":
        raise SmokeFailure(f"supervisor status != ok: {result}")
    if not result.get("bundled"):
        raise SmokeFailure("supervisor reports bundled=false; this is not the frozen bundle")
    reported = Path(str(result.get("executable", ""))).resolve()
    expected = (bundle / exe_name()).resolve()
    if reported != expected:
        raise SmokeFailure(f"supervisor executable mismatch: {reported} != {expected}")
    if result.get("pid") != proc.pid:
        raise SmokeFailure(
            f"/health answered by pid {result.get('pid')} but we launched pid {proc.pid}: "
            "a stale supervisor is running"
        )
    ok("supervisor identity matches launched bundle")
    return result


def wait_for_ready(proc: subprocess.Popen) -> dict:
    """The supervisor answers /health before it has spawned anything.

    ``ready`` flips once every child has been launched; ``phase`` and
    ``startup_error`` say why not if it never does.
    """
    health: dict = {}
    t0 = time.monotonic()

    def is_ready() -> bool:
        nonlocal health
        if proc.poll() is not None:
            raise SmokeFailure(f"supervisor died during startup (code {proc.returncode})")
        r = try_http("GET", f"http://{HOST}:{SUPERVISOR_PORT}/health", timeout=3)
        if not r or r[0] != 200 or not isinstance(r[1], dict):
            return False
        health = r[1]
        if health.get("startup_error"):
            raise SmokeFailure(f"supervisor startup failed: {health['startup_error']}")
        return bool(health.get("ready"))

    if not wait_until(is_ready, SERVICES_READY_TIMEOUT, interval=0.5):
        raise SmokeFailure(
            f"supervisor never reported ready within {SERVICES_READY_TIMEOUT:.0f}s "
            f"(phase={health.get('phase')})"
        )
    ok(f"supervisor ready (phase={health.get('phase')}) after {time.monotonic() - t0:.1f}s")
    return health


def wait_for_services(proc: subprocess.Popen) -> list[dict]:
    statuses: list[dict] = []

    def all_running() -> bool:
        nonlocal statuses
        if proc.poll() is not None:
            raise SmokeFailure(f"supervisor died while starting services (code {proc.returncode})")
        r = try_http("GET", f"http://{HOST}:{SUPERVISOR_PORT}/status", timeout=5)
        if not r or r[0] != 200 or not isinstance(r[1], dict):
            return False
        statuses = r[1].get("services", [])
        pending = []
        for s in statuses:
            if s["name"] == "training":  # deferred (Pro pack), never auto-started
                continue
            if s["status"] in ("failed", "error"):
                raise SmokeFailure(f"service {s['name']} is {s['status']}: {s.get('error')}")
            if s["status"] != "running":
                pending.append(s["name"])
                continue
            hr = try_http("GET", f"http://{HOST}:{s['port']}/health", timeout=3)
            if not hr or hr[0] != 200:
                pending.append(s["name"])
        return not pending

    t0 = time.monotonic()
    if not wait_until(all_running, SERVICES_READY_TIMEOUT, interval=1.0):
        names = [f"{s['name']}={s['status']}" for s in statuses]
        raise SmokeFailure(f"services not all healthy within {SERVICES_READY_TIMEOUT:.0f}s: {names}")
    running = [s["name"] for s in statuses if s["status"] == "running"]
    ok(f"{len(running)} services running and healthy after {time.monotonic() - t0:.1f}s: {', '.join(running)}")
    # Restart counters must be zero: a service that crashed once and was
    # revived is still a production bug.
    return statuses


def check_no_restarts(home: Path) -> None:
    sup_log = home / "logs" / "supervisor.log"
    if not sup_log.exists():
        return
    text = sup_log.read_text(encoding="utf-8", errors="replace")
    bad = [line for line in text.splitlines() if "Restarting " in line or "exited with code" in line or "Failed to start" in line]
    if bad:
        raise SmokeFailure("child services crashed/restarted during startup:\n  " + "\n  ".join(bad[:10]))
    ok("no child service crashed or restarted")


def check_inference_backends() -> dict:
    r = try_http("GET", f"http://{HOST}:{INFERENCE_PORT}/v1/backends", timeout=10)
    if not r or r[0] != 200 or not isinstance(r[1], dict):
        raise SmokeFailure(f"inference /v1/backends failed: {r}")
    backends = {b["name"]: b for b in r[1].get("backends", [])}
    llama = backends.get("llama_server")
    if llama is None:
        raise SmokeFailure(f"llama_server backend not registered; backends={list(backends)}")
    if not llama.get("online"):
        raise SmokeFailure(f"built-in llama_server backend offline: {llama.get('error')}")
    ok("built-in llama_server backend online (binary found in bundle)")
    return backends


def check_user_facing_endpoints() -> None:
    """Endpoints the app hits right after connecting.

    A router that fails to import is not visible from ``/health``; the
    first real request is where it shows.
    """
    r = try_http("GET", f"http://{HOST}:{INFERENCE_PORT}/v1/models", timeout=15)
    if not r or r[0] != 200 or not isinstance(r[1], dict) or "data" not in r[1]:
        raise SmokeFailure(f"inference /v1/models did not return a model list: {r}")
    r = try_http("GET", f"http://{HOST}:{SUPERVISOR_PORT}/api/pro-pack/status", timeout=10)
    if not r or r[0] != 200 or not isinstance(r[1], dict):
        raise SmokeFailure(f"supervisor /api/pro-pack/status failed: {r}")
    if r[1].get("installed") is not False:
        raise SmokeFailure(f"pro pack should be absent on a clean data dir, got {r[1]}")
    ok("/v1/models answers and Pro pack is correctly reported as not installed")


def check_recommendation() -> dict:
    # Hardware: wait for the background scan, then ask Autopilot.
    hw: dict | None = None

    def have_hw() -> bool:
        nonlocal hw
        r = try_http("GET", f"http://{HOST}:{SUPERVISOR_PORT}/hardware", timeout=5)
        if r and r[0] == 200 and isinstance(r[1], dict) and r[1].get("ram_bytes"):
            hw = r[1]
            return True
        return False

    if not wait_until(have_hw, 60.0, interval=1.0):
        raise SmokeFailure("hardware scan did not complete within 60s")
    assert hw is not None
    ok(f"hardware scan: {hw.get('cpu_name')} / {round(hw['ram_bytes'] / 2**30)} GiB RAM / gpu={hw.get('gpu_name')}")

    r = try_http(
        "POST",
        f"http://{HOST}:{MODEL_MANAGER_PORT}/models/recommend",
        {"hw_info": hw, "include_backends": True, "include_adapters": True},
        timeout=30,
    )
    if not r or r[0] != 200 or not isinstance(r[1], dict):
        raise SmokeFailure(f"model recommendation failed: {r}")
    recs = r[1].get("recommended") or []
    if not recs:
        raise SmokeFailure(f"Autopilot returned no recommendation: {json.dumps(r[1])[:300]}")
    top = recs[0]
    ok(
        f"Autopilot recommends: {top.get('name')} "
        f"({top.get('speed_rating')}, ~{top.get('predicted_tok_per_s')} tok/s)"
    )
    return r[1]


def run_chat(home: Path, gguf: Path) -> None:
    models_dir = home / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    dest = models_dir / gguf.name
    if not dest.exists():
        log(f"copying {gguf.name} into fresh models dir…")
        shutil.copy2(gguf, dest)
    chat_with(dest.stem.lower().replace(" ", "-"))


def chat_with(model_id: str) -> None:
    """Select ``model_id`` on the llama-server backend and get one completion."""
    r = try_http("GET", f"http://{HOST}:{INFERENCE_PORT}/v1/models", timeout=15)
    if not r or r[0] != 200:
        raise SmokeFailure(f"/v1/models failed: {r}")
    ids = [m.get("id") for m in (r[1] or {}).get("data", [])]
    if not any(model_id in (i or "") for i in ids):
        raise SmokeFailure(f"model {model_id} not discovered by inference; got {ids}")
    ok(f"model discovered by inference service: {model_id}")

    t0 = time.monotonic()
    r = try_http(
        "POST",
        f"http://{HOST}:{INFERENCE_PORT}/v1/models/select",
        {"model_id": model_id, "backend": "llama_server"},
        timeout=180,
    )
    if not r or r[0] != 200:
        raise SmokeFailure(f"model select failed: {r}")
    ok(f"model loaded via llama-server in {time.monotonic() - t0:.1f}s (active={r[1].get('active_model')})")

    t0 = time.monotonic()
    r = try_http(
        "POST",
        f"http://{HOST}:{INFERENCE_PORT}/v1/chat/completions",
        {
            "model": model_id,
            "messages": [{"role": "user", "content": "Reply with exactly the word: ready"}],
            "stream": False,
            "max_tokens": 16,
        },
        timeout=300,
    )
    if not r or r[0] != 200 or not isinstance(r[1], dict):
        raise SmokeFailure(f"chat completion failed: {r}")
    choices = r[1].get("choices") or []
    content = (choices[0].get("message") or {}).get("content", "") if choices else ""
    if not content.strip():
        raise SmokeFailure(f"chat completion returned empty content: {r[1]}")
    ok(f"first chat completion in {time.monotonic() - t0:.1f}s: {content.strip()[:80]!r}")


def run_download(repo: str, wait_seconds: float, to_completion: bool) -> str:
    """Add ``repo`` through the model manager and watch the download.

    With ``to_completion`` the download runs until the model manager reports
    ``complete`` (bounded by ``wait_seconds``) and the registered model id is
    returned for :func:`chat_with`. Otherwise the smoke only proves that
    resolution and streaming work, then cancels so CI does not pull gigabytes.
    """
    r = try_http(
        "POST",
        f"http://{HOST}:{MODEL_MANAGER_PORT}/models/add",
        {"source": "hf", "source_ref": repo},
        timeout=30,
    )
    if not r or r[0] != 200 or not isinstance(r[1], dict):
        raise SmokeFailure(f"models/add failed: {r}")
    model_id = r[1]["id"]
    status: dict = {}
    t0 = time.monotonic()
    last_report = 0.0

    def poll() -> bool:
        nonlocal status, last_report
        sr = try_http("GET", f"http://{HOST}:{MODEL_MANAGER_PORT}/models/status/{model_id}", timeout=10)
        if not sr or sr[0] != 200 or not isinstance(sr[1], dict):
            return False
        status = sr[1]
        if status.get("status") == "error":
            raise SmokeFailure(f"download errored: {status.get('error')}")
        if status.get("status") == "complete":
            return True
        if to_completion:
            now = time.monotonic()
            if now - last_report > 15:
                last_report = now
                log(
                    f"  downloading {model_id}: {status.get('downloaded_bytes', 0) / 2**20:.0f} / "
                    f"{status.get('total_bytes', 0) / 2**20:.0f} MiB ({status.get('speed_mbps', 0):.1f} MB/s)"
                )
            return False
        return status.get("downloaded_bytes", 0) > 0

    if not wait_until(poll, wait_seconds, interval=1.0):
        raise SmokeFailure(f"download did not {'complete' if to_completion else 'progress'} in {wait_seconds:.0f}s: {status}")

    mib = status.get("downloaded_bytes", 0) / 2**20
    total = status.get("total_bytes", 0) / 2**20
    if to_completion:
        ok(f"HF download completed without huggingface_hub: {model_id} {total:.0f} MiB in {time.monotonic() - t0:.0f}s")
        return model_id
    ok(f"HF download resolves + streams without huggingface_hub: {model_id} {mib:.1f} MiB of {total:.0f} MiB ({status.get('status')})")
    # Do not keep pulling gigabytes during a smoke test.
    try_http("DELETE", f"http://{HOST}:{MODEL_MANAGER_PORT}/models/{model_id}", timeout=15)
    return model_id


def shutdown_and_verify(proc: subprocess.Popen, child_pids_before: set[int]) -> None:
    r = try_http("POST", f"http://{HOST}:{SUPERVISOR_PORT}/shutdown", timeout=10)
    if not r or r[0] != 200:
        log(f"/shutdown returned {r}; falling back to SIGTERM")
        proc.send_signal(signal.SIGTERM)
    try:
        code = proc.wait(timeout=SHUTDOWN_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill()
        raise SmokeFailure(f"supervisor did not exit within {SHUTDOWN_TIMEOUT:.0f}s after /shutdown")
    ok(f"supervisor exited cleanly (code {code})")

    def ports_free() -> bool:
        return not any(port_in_use(p) for p in ALL_PORTS)

    if not wait_until(ports_free, 15.0):
        busy = {p: pids_on_port(p) for p in ALL_PORTS if port_in_use(p)}
        raise SmokeFailure(f"ports still held after shutdown: {busy}")
    ok("all service ports released (8100-8110, 8190)")

    leftovers = sorted(p for p in child_pids_before if _pid_alive(p))
    if leftovers:
        for p in leftovers:
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass
        raise SmokeFailure(f"child processes survived shutdown: {leftovers}")
    ok("no stale child processes")


def hard_kill_and_verify(bundle: Path, home: Path, log_path: Path) -> None:
    """Relaunch, SIGKILL the supervisor, and prove the children follow it.

    Children run in their own session, so nothing in the OS ties their
    lifetime to the supervisor. Before bundle_entry grew a supervisor
    watchdog, a force-quit left nine orphans on ports 8100-8109 and the
    next launch reported "backend not detected". This step guards that.
    """
    if platform.system() == "Windows":
        return
    proc = launch_supervisor(bundle, home, log_path)
    try:
        check_supervisor_health(proc, bundle)
        wait_for_ready(proc)
        wait_for_services(proc)
        children = collect_child_pids() - {proc.pid}
        if not children:
            raise SmokeFailure("no child pids found before hard kill")
        proc.kill()
        proc.wait(timeout=10)
        if not wait_until(
            lambda: not any(_pid_alive(p) for p in children) and not any(port_in_use(p) for p in ALL_PORTS),
            timeout=20,
            what="children exit after supervisor SIGKILL",
        ):
            leftovers = sorted(p for p in children if _pid_alive(p))
            for p in leftovers:
                try:
                    os.kill(p, signal.SIGKILL)
                except OSError:
                    pass
            raise SmokeFailure(f"children orphaned after supervisor SIGKILL: {leftovers}")
        ok(f"SIGKILLed supervisor: all {len(children)} children exited and released their ports")
    finally:
        if proc.poll() is None:
            proc.kill()


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def collect_child_pids() -> set[int]:
    pids: set[int] = set()
    for port in ALL_PORTS:
        pids.update(pids_on_port(port))
    return pids


def tail(path: Path, n: int = 40) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        return "\n".join(lines[-n:])
    except OSError:
        return "(no log)"


# ── Main ─────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--bundle", help="path to dist/studiomc_services")
    src.add_argument("--app", help="path to Studiomc.app (macOS) or the Flutter bundle dir")
    ap.add_argument("--gguf", help="small GGUF to load and chat with (proves inference end to end)")
    ap.add_argument("--download", metavar="HF_REPO", help="exercise the HF download path with this repo")
    ap.add_argument("--download-wait", type=float, default=45.0, help="seconds to wait for download progress")
    ap.add_argument(
        "--download-complete",
        action="store_true",
        help="let --download run to completion (bounded by --download-wait) and chat with the result",
    )
    ap.add_argument("--home", help="use this STUDIOMC_HOME instead of a fresh temp dir")
    ap.add_argument("--keep-home", action="store_true", help="do not delete the temp data dir")
    ap.add_argument("--force", action="store_true", help="run even if service ports are busy")
    ap.add_argument("--skip-selftest", action="store_true", help="do not run the frozen --selftest first")
    args = ap.parse_args()

    try:
        bundle = resolve_bundle(args)
    except SmokeFailure as exc:
        print(f"[smoke] ✗ {exc}", file=sys.stderr)
        return 2

    if args.home:
        home = Path(args.home).expanduser().resolve()
        home.mkdir(parents=True, exist_ok=True)
        cleanup_home = False
    else:
        home = Path(tempfile.mkdtemp(prefix="studiomc-fresh-"))
        cleanup_home = not args.keep_home

    stdout_log = home / "supervisor.stdout.log"
    proc: subprocess.Popen | None = None
    failures: list[str] = []
    try:
        preflight(args.force)
        if not args.skip_selftest:
            run_selftest(bundle, home)
        proc = launch_supervisor(bundle, home, stdout_log)
        check_supervisor_health(proc, bundle)
        wait_for_ready(proc)
        wait_for_services(proc)
        check_no_restarts(home)
        check_inference_backends()
        check_user_facing_endpoints()
        check_recommendation()
        if args.download:
            downloaded = run_download(args.download, args.download_wait, args.download_complete)
            if args.download_complete:
                chat_with(downloaded)
        if args.gguf:
            run_chat(home, Path(args.gguf).expanduser().resolve())
        children = collect_child_pids()
        shutdown_and_verify(proc, children - {proc.pid})
        hard_kill_and_verify(bundle, home, stdout_log)
    except SmokeFailure as exc:
        failures.append(str(exc))
    except KeyboardInterrupt:
        failures.append("interrupted")
    finally:
        if proc is not None and proc.poll() is None:
            try:
                proc.send_signal(signal.SIGTERM)
                proc.wait(timeout=10)
            except Exception:
                proc.kill()
        # Belt and braces: never leave a smoke run holding the ports.
        for port in ALL_PORTS:
            for pid in pids_on_port(port):
                if pid != os.getpid():
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except OSError:
                        pass

    if failures:
        print(f"\n[smoke] ✗ FAILED: {failures[0]}", file=sys.stderr)
        print(f"\n[smoke] --- supervisor stdout/stderr ({stdout_log}) ---", file=sys.stderr)
        print(tail(stdout_log), file=sys.stderr)
        for name in ("supervisor", "inference", "model_manager", "documents", "clara"):
            p = home / "logs" / f"{name}.log"
            if p.exists():
                print(f"\n[smoke] --- {p} ---", file=sys.stderr)
                print(tail(p, 25), file=sys.stderr)
        if cleanup_home:
            print(f"[smoke] data dir kept for inspection: {home}", file=sys.stderr)
        return 1

    if cleanup_home:
        shutil.rmtree(home, ignore_errors=True)
    print("\n[smoke] ✓ PASSED: fresh install of this bundle works end to end")
    return 0


if __name__ == "__main__":
    sys.exit(main())
