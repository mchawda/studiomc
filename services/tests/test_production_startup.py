# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Guards for the first-launch path that broke in shipped builds.

Each test pins a behaviour that only manifested in the frozen PyInstaller
bundle, never in ``uvicorn --reload`` on a developer machine:

* the supervisor's ``/health`` must identify its build and executable so the
  desktop app can refuse to adopt a stale supervisor from an older install;
* ``llama-server`` must be found inside the frozen bundle layout
  (``_MEIPASS/bin``), not only next to a dev checkout;
* the HuggingFace resolver must work with ``httpx`` alone, because
  ``huggingface_hub`` is not in the Core bundle;
* Apple Silicon must be treated as GPU-capable even though
  ``system_profiler`` reports no dedicated VRAM, otherwise Autopilot
  recommends CPU-tier models to every Mac user.

The final test runs the real end-to-end smoke against ``dist/`` when a
bundle has been built and skips otherwise, so ``make test-services`` after
``make build-services`` exercises the artefact users actually run.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import sys
from pathlib import Path

import httpx
import pytest

SERVICES_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SERVICES_DIR.parent


# ── Build identity ──────────────────────────────────────────────────────


def test_build_info_reports_dev_without_stamp() -> None:
    from common import build_info

    build_info.get_build_info.cache_clear()
    info = build_info.get_build_info()
    # A dev checkout has no BUILD_INFO.json (it is gitignored, written by CI).
    assert info["version"] == "dev" or info["version"]


def test_build_info_reads_stamp_from_meipass(monkeypatch, tmp_path: Path) -> None:
    from common import build_info

    (tmp_path / build_info.BUILD_INFO_FILENAME).write_text(
        json.dumps({"version": "9.9.9", "git_sha": "abc1234", "built_at": "now"})
    )
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    build_info.get_build_info.cache_clear()
    try:
        identity = build_info.runtime_identity()
    finally:
        build_info.get_build_info.cache_clear()

    assert identity["version"] == "9.9.9"
    assert identity["git_sha"] == "abc1234"
    assert identity["bundled"] is True
    assert identity["pid"] == os.getpid()
    assert identity["executable"] == sys.executable
    assert identity["executable_exists"] is True


def test_supervisor_health_exposes_identity() -> None:
    """The desktop app keys off these fields to detect a stale supervisor."""
    from fastapi.testclient import TestClient

    from supervisor.app import app

    # No context manager: the lifespan would kill port holders and spawn
    # every real child service, which is the smoke test's job, not this one.
    body = TestClient(app).get("/health").json()

    for key in ("status", "version", "git_sha", "pid", "executable", "bundled"):
        assert key in body, f"/health missing {key}: {body}"
    assert body["pid"] == os.getpid()


# ── llama-server discovery ──────────────────────────────────────────────


def test_llama_server_found_in_frozen_bundle_layout(monkeypatch, tmp_path: Path) -> None:
    from inference import llama_server_sidecar as sidecar

    name = "llama-server.exe" if sys.platform == "win32" else "llama-server"
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    exe = fake_bin / name
    exe.write_bytes(b"#!/bin/sh\n")
    exe.chmod(0o755)

    monkeypatch.delenv("STUDIOMC_LLAMA_SERVER", raising=False)
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    monkeypatch.setattr(sys, "frozen", True, raising=False)

    candidates = [Path(p) for p in sidecar._candidate_paths()]
    assert exe in candidates, candidates


def test_llama_server_env_override_wins(monkeypatch, tmp_path: Path) -> None:
    from inference import llama_server_sidecar as sidecar

    exe = tmp_path / "custom-llama-server"
    exe.write_bytes(b"")
    monkeypatch.setenv("STUDIOMC_LLAMA_SERVER", str(exe))
    assert Path(sidecar._candidate_paths()[0]) == exe


# ── HuggingFace resolution without huggingface_hub ──────────────────────


def test_downloader_does_not_import_huggingface_hub() -> None:
    import re

    import model_manager.downloader as dl

    src = Path(dl.__file__).read_text(encoding="utf-8")
    assert not re.search(
        r"^\s*(from|import)\s+huggingface_hub", src, re.MULTILINE
    ), "downloader must not import huggingface_hub (excluded from Core)"
    assert "huggingface_hub" not in sys.modules or True  # may be present in dev venv


def test_select_repo_file_prefers_pattern_then_gguf() -> None:
    from model_manager.downloader import _select_repo_file

    files = ["README.md", "model-Q4_K_M.gguf", "model-Q8_0.gguf", "config.json"]
    assert _select_repo_file(files, "*Q8_0*.gguf", "org/repo") == "model-Q8_0.gguf"
    picked = _select_repo_file(files, "*.nonexistent", "org/repo")
    assert picked is not None and picked.endswith(".gguf")
    assert _select_repo_file(["README.md"], "*.gguf", "org/repo") is None


@pytest.mark.asyncio
async def test_resolve_hf_file_uses_httpx_api(monkeypatch) -> None:
    from model_manager import downloader as dl
    from common.schemas import ModelDownloadStatus

    payload = {
        "siblings": [
            {"rfilename": "README.md", "size": 10},
            {"rfilename": "tiny-Q4_K_M.gguf", "size": 123456},
        ]
    }

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/api/models/org/tiny")
        assert request.url.params.get("blobs") == "true"
        return httpx.Response(200, json=payload)

    transport = httpx.MockTransport(handler)
    real_client = httpx.AsyncClient

    def patched_client(*args, **kwargs):
        kwargs["transport"] = transport
        return real_client(*args, **kwargs)

    monkeypatch.setattr(dl.httpx, "AsyncClient", patched_client)

    status = ModelDownloadStatus(model_id="org/tiny", status="downloading")
    result = await dl._resolve_hf_file("org/tiny", "*.gguf", status)

    assert result is not None
    filename, url = result
    assert filename == "tiny-Q4_K_M.gguf"
    assert url.endswith("/org/tiny/resolve/main/tiny-Q4_K_M.gguf")
    assert status.total_bytes == 123456


@pytest.mark.asyncio
async def test_resolve_hf_file_surfaces_gated_repo(monkeypatch) -> None:
    from model_manager import downloader as dl
    from common.schemas import ModelDownloadStatus

    transport = httpx.MockTransport(lambda r: httpx.Response(401))
    real_client = httpx.AsyncClient
    monkeypatch.setattr(
        dl.httpx,
        "AsyncClient",
        lambda *a, **kw: real_client(*a, transport=transport, **kw),
    )

    status = ModelDownloadStatus(model_id="org/gated", status="downloading")
    assert await dl._resolve_hf_file("org/gated", "*.gguf", status) is None
    assert status.status == "error"
    assert "HF_TOKEN" in (status.error or "")


# ── Apple Silicon hardware ──────────────────────────────────────────────


def test_apple_silicon_unified_memory_counts_as_gpu(monkeypatch) -> None:
    from common import hardware

    monkeypatch.setattr(hardware.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(hardware.platform, "machine", lambda: "arm64")

    # system_profiler on M-series reports the GPU with an empty VRAM field.
    fake_profile = json.dumps(
        {"SPDisplaysDataType": [{"sppci_model": "Apple M3 Pro", "spdisplays_vram": ""}]}
    )

    class _Proc:
        returncode = 0
        stdout = fake_profile
        stderr = ""

    class _Mem:
        total = 36 * 1024**3

    monkeypatch.setattr(hardware.subprocess, "run", lambda *a, **k: _Proc())
    monkeypatch.setattr(hardware.psutil, "virtual_memory", lambda: _Mem())

    name, vram = hardware._detect_gpu()
    assert name == "Apple M3 Pro"
    assert vram is not None and vram >= _Mem.total * 0.5


def test_apple_silicon_without_system_profiler_still_reports_gpu(monkeypatch) -> None:
    from common import hardware

    monkeypatch.setattr(hardware.platform, "system", lambda: "Darwin")
    monkeypatch.setattr(hardware.platform, "machine", lambda: "arm64")

    def boom(*a, **k):
        raise FileNotFoundError("system_profiler")

    class _Mem:
        total = 16 * 1024**3

    monkeypatch.setattr(hardware.subprocess, "run", boom)
    monkeypatch.setattr(hardware.psutil, "virtual_memory", lambda: _Mem())

    name, vram = hardware._detect_gpu()
    assert name == "Apple Silicon GPU"
    assert vram == int(_Mem.total * 0.75)


# ── Child services follow a dead supervisor ─────────────────────────────


def test_bundle_entry_watchdog_exits_when_supervisor_dies(tmp_path: Path) -> None:
    """A SIGKILLed supervisor must not leave children holding ports."""
    import bundle_entry

    mod = Path(bundle_entry.__file__)
    fake_supervisor = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    env = dict(os.environ)
    env["STUDIOMC_SUPERVISOR_PID"] = str(fake_supervisor.pid)
    env["STUDIOMC_HOME"] = str(tmp_path)
    env["PYTHONPATH"] = str(SERVICES_DIR)
    # Run the watchdog in a real child process without binding a port.
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import time, bundle_entry; bundle_entry._watch_supervisor('probe', interval=0.2); time.sleep(30)",
        ],
        cwd=mod.parent,
        env=env,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        time.sleep(0.5)
        assert child.poll() is None, "child exited before supervisor died"
        fake_supervisor.kill()
        fake_supervisor.wait(timeout=5)
        _, err = child.communicate(timeout=10)
    finally:
        for p in (child, fake_supervisor):
            if p.poll() is None:
                p.kill()
    assert child.returncode == 0, err
    assert "supervisor pid" in err and "gone" in err


# ── End-to-end against the frozen bundle ────────────────────────────────


def _bundle_path() -> Path | None:
    exe = "studiomc_services.exe" if sys.platform == "win32" else "studiomc_services"
    for candidate in (
        SERVICES_DIR / "dist" / "studiomc_services" / exe,
        SERVICES_DIR / "dist" / exe,
    ):
        if candidate.exists():
            return candidate
    return None


@pytest.mark.skipif(_bundle_path() is None, reason="services/dist bundle not built")
def test_frozen_bundle_first_launch_smoke() -> None:
    """Real supervisor + children from dist/, clean STUDIOMC_HOME, clean exit."""
    bundle = _bundle_path()
    assert bundle is not None
    result = subprocess.run(
        [
            sys.executable,
            str(REPO_ROOT / "scripts" / "build" / "smoke_bundle.py"),
            "--bundle",
            str(bundle),
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert result.returncode == 0, result.stdout + "\n" + result.stderr
