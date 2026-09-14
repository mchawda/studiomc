# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Regression test: PyInstaller spec lists every managed service.

When a new service is added to ``supervisor.manager.MANAGED_SERVICES`` the
PyInstaller spec at ``services/studiomc_services.spec`` must also list:

* ``<service>.app`` in ``hidden_imports`` (so PyInstaller bundles it)
* ``(<service>, <service>)`` in ``datas`` (so the package source files
  are shipped alongside the frozen executable)

If either is missing, the bundled build will succeed but the supervisor
will fail to spawn the service at runtime with a cryptic
``Cannot import <service>.app: No module named '<service>'``. This test
catches the omission at unit-test time.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from supervisor.manager import MANAGED_SERVICES

SPEC_PATH = Path(__file__).parent.parent / "studiomc_services.spec"


@pytest.fixture(scope="module")
def spec_text() -> str:
    assert SPEC_PATH.is_file(), f"PyInstaller spec missing at {SPEC_PATH}"
    return SPEC_PATH.read_text(encoding="utf-8")


@pytest.mark.parametrize("service_name", sorted(MANAGED_SERVICES.keys()))
def test_spec_lists_service_app_as_hidden_import(
    service_name: str,
    spec_text: str,
) -> None:
    """``<service>.app`` must appear in the spec so PyInstaller bundles it."""
    needle = f'"{service_name}.app"'
    assert needle in spec_text, (
        f"PyInstaller spec is missing hidden import {needle}. "
        "Add it to the hidden_imports list in studiomc_services.spec or "
        "the bundled build will fail to spawn this service."
    )


@pytest.mark.parametrize("service_name", sorted(MANAGED_SERVICES.keys()))
def test_spec_includes_service_package_as_data(
    service_name: str,
    spec_text: str,
) -> None:
    """The service package directory must be in ``datas``.

    Without this PyInstaller's runtime ``importlib.import_module(...)``
    cannot find the package source under ``_MEIPASS``.
    """
    needle = f'("{service_name}", "{service_name}")'
    assert needle in spec_text, (
        f"PyInstaller spec is missing datas entry {needle}. "
        "Add it to the datas list in studiomc_services.spec so the "
        "package source ships with the bundle."
    )
