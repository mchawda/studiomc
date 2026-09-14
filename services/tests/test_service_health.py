# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Regression test: every managed service must expose ``/health`` at the root.

The supervisor (`services/supervisor/manager.py`) probes each child service
at ``http://127.0.0.1:<port>/health``. If a service mounts its only
``/health`` route under an ``APIRouter(prefix=...)`` (e.g. ``/recipes``,
``/training``, ``/lre``), the supervisor probe lands on a 404 and the
service is repeatedly marked unhealthy and restarted until it's
permanently failed. This test exercises the FastAPI app of every service
under the same path the supervisor uses, so a new prefixed service can
never sneak in without a root-level health alias.
"""

from __future__ import annotations

import importlib

import pytest
from fastapi.testclient import TestClient

from supervisor.manager import MANAGED_SERVICES


@pytest.mark.parametrize("service_name", sorted(MANAGED_SERVICES.keys()))
def test_service_exposes_root_health(service_name: str) -> None:
    """Every managed service must answer 200 to ``GET /health``."""
    module = importlib.import_module(f"{service_name}.app")
    app = getattr(module, "app", None)
    assert app is not None, f"{service_name}.app has no FastAPI ``app``"

    with TestClient(app) as client:
        response = client.get("/health")

    assert response.status_code == 200, (
        f"{service_name} must expose /health at the root "
        f"(supervisor probes there). Got HTTP {response.status_code}: "
        f"{response.text[:200]}"
    )
    payload = response.json()
    assert isinstance(payload, dict)
    assert payload.get("status") == "ok"
