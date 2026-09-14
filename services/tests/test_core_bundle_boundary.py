# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Guard the whole Core bundle, not just hand-picked modules.

``test_core_imports.py`` checks an allow-list of modules with a blocking
``__import__``. That list drifts: a new service (``mcp``, ``memory``,
``eval``) or a new lazy import can add a torch dependency without anyone
touching the list. These tests instead derive the surface from the
supervisor's own ``MANAGED_SERVICES`` table so the boundary is enforced for
exactly the set of processes the frozen bundle will spawn.

They run under the Core-only dependency set in CI (no torch installed), so
``import torch`` inside a Core module fails loudly here instead of on a
user's machine where the PyInstaller ``excludes`` list silently dropped it.
"""

from __future__ import annotations

import importlib
import sys

import pytest

from supervisor.manager import DEFERRED_SERVICES, MANAGED_SERVICES

PRO_ONLY_ROOTS = {
    "torch",
    "torchvision",
    "torchaudio",
    "transformers",
    "peft",
    "accelerate",
    "sentence_transformers",
    "safetensors",
    "mlx",
    "mlx_lm",
    "llama_cpp",
    "unsloth",
}

CORE_SERVICE_APPS = sorted(
    f"{name}.app" for name in MANAGED_SERVICES if name not in DEFERRED_SERVICES
) + ["supervisor.app"]


def _leaked_pro_modules() -> list[str]:
    return sorted(m for m in sys.modules if m.split(".", 1)[0] in PRO_ONLY_ROOTS)


@pytest.mark.parametrize("module_name", CORE_SERVICE_APPS)
def test_core_service_app_imports_without_pro_modules(module_name: str) -> None:
    """Importing a Core service app must not pull any Pro-only library."""
    mod = importlib.import_module(module_name)
    assert getattr(mod, "app", None) is not None, f"{module_name} has no FastAPI app"
    leaked = _leaked_pro_modules()
    assert not leaked, (
        f"{module_name} caused Pro-only modules to load: {leaked}. "
        "Move the import behind common.pro_pack.require() or into the "
        "training subprocess (see SPLIT_BUNDLE.md)."
    )


def test_bundle_entry_selftest_passes_in_source_checkout() -> None:
    """The frozen ``--selftest`` mode must also pass unfrozen.

    CI runs the same routine inside the PyInstaller output; keeping it
    green in the source tree means a red bundle run points at packaging,
    not at the code.
    """
    import bundle_entry

    bundle_entry._fixup_paths()
    bundle_entry._run_selftest()


_FIRST_PARTY_PROBE = r"""
import importlib, json, sys
from pathlib import Path
root = Path.cwd().resolve()
for name in json.loads(sys.argv[1]):
    importlib.import_module(name)
pkgs = set()
for mod, obj in list(sys.modules.items()):
    file = getattr(obj, "__file__", None)
    if not file:
        continue
    path = Path(file).resolve()
    if not str(path).startswith(str(root)) or ".venv" in path.parts or "tests" in path.parts:
        continue
    pkgs.add(mod.split(".", 1)[0])
print(json.dumps(sorted(pkgs)))
"""


def test_every_first_party_package_used_by_core_is_shipped_as_data() -> None:
    """Belt and braces on top of test_pyinstaller_spec: every first-party
    package a Core service pulls in at import time must be listed in the
    spec's ``datas`` so its source ships next to the frozen executable.

    Runs in a fresh interpreter so modules imported by other tests (``eval``,
    ``training.studiomc_model``) do not pollute the measurement.
    """
    import json
    import subprocess
    from pathlib import Path

    services_dir = Path(__file__).parent.parent
    spec_text = (services_dir / "studiomc_services.spec").read_text(encoding="utf-8")
    result = subprocess.run(
        [sys.executable, "-c", _FIRST_PARTY_PROBE, json.dumps(CORE_SERVICE_APPS)],
        cwd=services_dir,
        capture_output=True,
        text=True,
        timeout=120,
        check=True,
    )
    first_party = set(json.loads(result.stdout.strip().splitlines()[-1]))
    first_party.discard("bundle_entry")
    assert first_party >= {"common", "inference", "supervisor"}, first_party
    missing = sorted(p for p in first_party if f'("{p}", "{p}")' not in spec_text)
    assert not missing, (
        f"First-party packages imported by Core services but not listed in the "
        f"PyInstaller spec datas: {missing}"
    )
