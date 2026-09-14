# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Single source of truth for the Studiomc **Pro pack**.

The Pro pack is an optional, lazy-downloaded bundle (~1.2 GB) containing
the heavy ML stack (PyTorch, transformers, peft, accelerate,
sentence-transformers, MLX on Apple Silicon, plus the SpliceLLM
out-of-core engine). It is downloaded the first time a user opens the
Training screen (or activates SpliceLLM / neural CLaRa retrieval).

Why this module exists
----------------------
Every layer that *might* need the Pro pack must consult this module
instead of importing the heavy libraries directly. That keeps the Core
bundle (FastAPI + llama-server sidecar + lightweight orchestration) at
~80 MB and lets the supervisor decide at runtime whether to:

* run the request in-process (Pro pack present), or
* spawn a separate ``trainer`` subprocess pointed at the Pro venv, or
* refuse the request with a structured ``pro_pack_required`` response
  that the Flutter UI maps to the download dialog.

Layout on disk
--------------
::

    ~/Library/Application Support/Studiomc/      (macOS)
    ~/.local/share/studiomc/                     (Linux)
    %APPDATA%/studiomc/                          (Windows)
    └── pro-env/
        ├── VERSION              # plain text, e.g. "0.1.0"
        ├── INSTALLED_AT         # ISO-8601 timestamp
        ├── bin/python           # venv interpreter
        ├── lib/python3.11/site-packages/
        │   ├── torch/
        │   ├── transformers/
        │   ├── peft/
        │   └── ...
        └── manifest.json        # package list + sha256 of tarball

The Pro pack is **never** loaded into the supervisor's own interpreter.
Training and SpliceLLM run in dedicated subprocesses spawned with
``pro-env/bin/python`` so PyTorch import cost is paid only when the
user actually trains, and an OOM in training cannot kill the chat UI.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from common.config import ROOT

# ── Layout ────────────────────────────────────────────────────────────

PRO_ENV_DIR: Path = ROOT / "pro-env"
PRO_VERSION_FILE: Path = PRO_ENV_DIR / "VERSION"
PRO_MANIFEST_FILE: Path = PRO_ENV_DIR / "manifest.json"

# Minimum Pro pack version this build of Studiomc requires. Bump when we
# break compatibility (e.g. require a newer transformers/torch).
REQUIRED_PRO_VERSION = "0.1.0"


def pro_python_path() -> Path:
    """Return the path to the Pro venv's Python interpreter."""
    if os.name == "nt":  # pragma: no cover — Windows
        return PRO_ENV_DIR / "Scripts" / "python.exe"
    return PRO_ENV_DIR / "bin" / "python"


# ── Status ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class ProPackStatus:
    """Reported by ``/api/pro-pack/status`` and consumed by the Flutter UI."""

    installed: bool
    version: str | None
    python_path: str | None
    needs_upgrade: bool

    def to_dict(self) -> dict[str, object]:
        return {
            "installed": self.installed,
            "version": self.version,
            "python_path": self.python_path,
            "needs_upgrade": self.needs_upgrade,
            "required_version": REQUIRED_PRO_VERSION,
        }


def get_status() -> ProPackStatus:
    """Inspect the filesystem to determine the Pro pack's install state.

    Cheap (one file stat + one read of a tiny VERSION file) — safe to
    call from request handlers.
    """
    py = pro_python_path()
    if not py.exists() or not PRO_VERSION_FILE.exists():
        return ProPackStatus(
            installed=False, version=None, python_path=None, needs_upgrade=False
        )

    try:
        version = PRO_VERSION_FILE.read_text(encoding="utf-8").strip()
    except OSError:
        version = None

    needs_upgrade = (version or "0.0.0") < REQUIRED_PRO_VERSION
    return ProPackStatus(
        installed=True,
        version=version,
        python_path=str(py),
        needs_upgrade=needs_upgrade,
    )


def is_installed() -> bool:
    """Convenience boolean — for ``if pro_pack.is_installed(): ...`` checks."""
    return get_status().installed


# ── Manifest ──────────────────────────────────────────────────────────

def read_manifest() -> dict[str, object] | None:
    """Return the JSON manifest if present, else ``None``.

    The manifest is written by the installer and contains:

    * ``packages``   — list of {name, version} for sanity checking
    * ``sha256``     — hash of the tarball that was extracted
    * ``platform``   — "macos-arm64" / "macos-x64" / "linux-x64" / etc.
    """
    if not PRO_MANIFEST_FILE.exists():
        return None
    try:
        return json.loads(PRO_MANIFEST_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


# ── Errors ────────────────────────────────────────────────────────────

class ProPackRequiredError(RuntimeError):
    """Raised by feature code when the Pro pack is needed but missing.

    FastAPI exception handlers turn this into a 412 Precondition Failed
    response carrying ``{"error": "pro_pack_required", ...}`` so the
    Flutter UI can pop the install dialog instead of showing a generic
    500.
    """

    def __init__(self, feature: str) -> None:
        super().__init__(
            f"The '{feature}' feature requires the Studiomc Pro pack. "
            f"Install it from the Training screen."
        )
        self.feature = feature


def require(feature: str) -> ProPackStatus:
    """Guard helper: return status if installed, else raise.

    Usage::

        from common.pro_pack import require
        require("training")
        # ... safe to import torch ...
    """
    status = get_status()
    if not status.installed or status.needs_upgrade:
        raise ProPackRequiredError(feature)
    return status
