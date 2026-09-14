# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc Services — single entry-point for PyInstaller bundle.

When packaged with PyInstaller, this module IS the executable. It supports
two modes:

  studiomc_services                     → launch the supervisor (default)
  studiomc_services --service inference  → launch a specific child service

The supervisor's ProcessManager calls `sys.executable --service <name>` to
spawn child services, which works in both development and bundled modes.
"""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
from pathlib import Path


def _fixup_paths() -> None:
    """Ensure service packages are importable.

    In a PyInstaller --onedir bundle, _MEIPASS points to the temporary
    extraction directory. We add it (and the CWD for dev mode) to sys.path
    so that ``import inference.app`` etc. resolve correctly.
    """
    base = getattr(sys, "_MEIPASS", None)
    if base:
        base = str(base)
    else:
        # Development fallback: services/ directory
        base = str(Path(__file__).parent)

    if base not in sys.path:
        sys.path.insert(0, base)


def _run_supervisor() -> None:
    """Start the supervisor service (default mode)."""
    import uvicorn

    from common.config import SERVICE_HOST, SUPERVISOR_PORT
    from supervisor.app import app, manager

    manager.kill_stale_port_holders()

    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=SUPERVISOR_PORT,
        reload=False,
        log_level="info",
    )


def _pid_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _watch_supervisor(name: str, interval: float = 2.0) -> None:
    """Exit this child when the supervisor that spawned it is gone.

    Children are started in their own session so that signals aimed at the
    supervisor do not interrupt them. That also means a SIGKILLed or
    crashed supervisor (force quit, OOM, process-group kill) would leave
    nine orphans holding ports 8100-8109 until the next launch tripped over
    them. Watching the supervisor pid closes that gap in every mode.
    """
    raw = os.environ.get("STUDIOMC_SUPERVISOR_PID")
    try:
        supervisor_pid = int(raw) if raw else os.getppid()
    except ValueError:
        supervisor_pid = os.getppid()
    if supervisor_pid <= 1:
        return

    def loop() -> None:
        while True:
            time.sleep(interval)
            # On POSIX an orphan is reparented to pid 1 (launchd/init).
            if not _pid_alive(supervisor_pid) or os.getppid() == 1:
                print(
                    f"[bundle_entry] supervisor pid={supervisor_pid} gone; "
                    f"stopping {name}",
                    file=sys.stderr,
                    flush=True,
                )
                os._exit(0)

    threading.Thread(target=loop, name="supervisor-watchdog", daemon=True).start()


def _run_service(name: str) -> None:
    """Start a child service by name.

    Each service directory contains an ``app.py`` with a FastAPI ``app``
    instance and a standard ``if __name__ == '__main__'`` block.  Rather
    than exec-ing that file, we import the module and call uvicorn directly
    so that PyInstaller can trace the imports.
    """
    import importlib

    import uvicorn

    from common.config import ALL_PORTS, SERVICE_HOST

    port = ALL_PORTS.get(name)
    if port is None:
        print(f"[bundle_entry] Unknown service: {name}", file=sys.stderr)
        sys.exit(1)

    try:
        mod = importlib.import_module(f"{name}.app")
    except ImportError as exc:
        print(
            f"[bundle_entry] Cannot import {name}.app: {exc}",
            file=sys.stderr,
        )
        sys.exit(1)

    app = getattr(mod, "app", None)
    if app is None:
        print(
            f"[bundle_entry] {name}.app has no 'app' attribute",
            file=sys.stderr,
        )
        sys.exit(1)

    _watch_supervisor(name)

    uvicorn.run(
        app,
        host=SERVICE_HOST,
        port=port,
        reload=False,
        log_level="info",
    )


# Heavy ML libraries that live in the Pro pack venv. If any of these show
# up in ``sys.modules`` after importing the Core services, the split
# bundle contract is broken (see SPLIT_BUNDLE.md) and the frozen build is
# either bloated or, worse, crashes at import time on a fresh machine.
_PRO_ONLY_ROOTS = (
    "torch",
    "transformers",
    "peft",
    "accelerate",
    "sentence_transformers",
    "safetensors",
    "mlx",
    "mlx_lm",
    "llama_cpp",
    "unsloth",
)


def _run_selftest() -> None:
    """Import every Core service the supervisor will spawn and exit.

    PyInstaller silently drops modules it cannot trace (``importlib``
    string imports, lazy imports behind ``try``) and its ``excludes`` list
    only *skips* packages instead of failing the build. Both failure
    modes surface on the user's machine as ``Cannot import <svc>.app``
    in a child-service log while the supervisor itself looks healthy.
    Running this inside the frozen executable is the only way to catch
    them before a release ships.
    """
    import importlib
    import traceback

    from supervisor.manager import DEFERRED_SERVICES, MANAGED_SERVICES

    frozen = getattr(sys, "frozen", False)
    print(f"[selftest] frozen={frozen} executable={sys.executable}")

    failures: list[str] = []
    core_services = [n for n in MANAGED_SERVICES if n not in DEFERRED_SERVICES]
    for name in ["supervisor", *core_services]:
        mod_name = f"{name}.app"
        try:
            mod = importlib.import_module(mod_name)
        except Exception:
            failures.append(f"{mod_name}: import failed\n{traceback.format_exc()}")
            print(f"[selftest] FAIL  {mod_name}")
            continue
        if getattr(mod, "app", None) is None:
            failures.append(f"{mod_name}: no 'app' attribute")
            print(f"[selftest] FAIL  {mod_name} (no app)")
            continue
        print(f"[selftest] ok    {mod_name}")

    # Deferred services run under the Pro venv, but their *source* must
    # still ship as data so ``pro-env/bin/python training/app.py`` works.
    base = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))
    for name in DEFERRED_SERVICES:
        rel = MANAGED_SERVICES[name]
        if not (base / rel).is_file():
            failures.append(f"{name}: {rel} missing from bundle data at {base}")
            print(f"[selftest] FAIL  {name} ({rel} not shipped)")
        else:
            print(f"[selftest] ok    {name} ({rel} shipped as data)")

    leaked = sorted(
        m for m in sys.modules if m.split(".", 1)[0] in _PRO_ONLY_ROOTS
    )
    if leaked:
        failures.append(
            "Pro-only modules imported by Core services: " + ", ".join(leaked[:20])
        )
        print(f"[selftest] FAIL  Pro-only modules leaked into Core: {leaked[:20]}")
    else:
        print("[selftest] ok    no Pro-only modules imported")

    if failures:
        print("\n[selftest] FAILED\n" + "\n".join(failures), file=sys.stderr)
        sys.exit(1)
    print("[selftest] PASSED")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Studiomc backend services entry-point.",
    )
    parser.add_argument(
        "--service",
        type=str,
        default=None,
        help="Name of the child service to launch (e.g. inference, clara). "
        "If omitted, the supervisor is started.",
    )
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Import every Core service inside this executable, verify no "
        "Pro-only library leaked in, then exit 0/1. Used by CI.",
    )
    args = parser.parse_args()

    _fixup_paths()

    if args.selftest:
        _run_selftest()
    elif args.service:
        _run_service(args.service)
    else:
        _run_supervisor()


if __name__ == "__main__":
    main()
