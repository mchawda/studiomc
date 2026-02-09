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
import sys
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
    from common.config import SUPERVISOR_PORT
    from supervisor.app import app

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=SUPERVISOR_PORT,
        reload=False,
        log_level="info",
    )


def _run_service(name: str) -> None:
    """Start a child service by name.

    Each service directory contains an ``app.py`` with a FastAPI ``app``
    instance and a standard ``if __name__ == '__main__'`` block.  Rather
    than exec-ing that file, we import the module and call uvicorn directly
    so that PyInstaller can trace the imports.
    """
    import importlib

    import uvicorn
    from common.config import ALL_PORTS

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

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=port,
        reload=False,
        log_level="info",
    )


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
    args = parser.parse_args()

    _fixup_paths()

    if args.service:
        _run_service(args.service)
    else:
        _run_supervisor()


if __name__ == "__main__":
    main()
