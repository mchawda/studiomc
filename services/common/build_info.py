# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Identity of the running backend build.

``scripts/build/build_services.sh`` writes ``BUILD_INFO.json`` next to the
service packages before PyInstaller runs, and the spec ships it as data.
In a development checkout the file is absent and we report ``"dev"``.

The supervisor exposes this via ``GET /health`` so the desktop app can
tell whether the supervisor it found on port 8110 belongs to the bundle
it is running from, or is a stale process left behind by an older
install. Reusing a stale supervisor is how an app upgrade ends up talking
to a backend whose executable no longer exists on disk.
"""

from __future__ import annotations

import json
import os
import sys
import time
from functools import lru_cache
from pathlib import Path
from typing import Any

BUILD_INFO_FILENAME = "BUILD_INFO.json"

_STARTED_AT = time.time()


def _search_dirs() -> list[Path]:
    dirs: list[Path] = []
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        dirs.append(Path(meipass))
    dirs.append(Path(__file__).resolve().parent.parent)
    return dirs


@lru_cache(maxsize=1)
def get_build_info() -> dict[str, Any]:
    """Return ``{"version", "git_sha", "built_at"}`` for this build."""
    for d in _search_dirs():
        candidate = d / BUILD_INFO_FILENAME
        if candidate.is_file():
            try:
                data = json.loads(candidate.read_text(encoding="utf-8"))
                if isinstance(data, dict):
                    return {
                        "version": str(data.get("version", "unknown")),
                        "git_sha": str(data.get("git_sha", "unknown")),
                        "built_at": str(data.get("built_at", "unknown")),
                    }
            except (OSError, json.JSONDecodeError):
                break
    return {"version": "dev", "git_sha": "dev", "built_at": "dev"}


def runtime_identity() -> dict[str, Any]:
    """Everything a client needs to decide whether this supervisor is *theirs*."""
    info = dict(get_build_info())
    info.update(
        {
            "pid": os.getpid(),
            "executable": sys.executable,
            "bundled": getattr(sys, "_MEIPASS", None) is not None,
            "started_at": _STARTED_AT,
            "executable_exists": Path(sys.executable).exists(),
        }
    )
    return info
