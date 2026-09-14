# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Every torch-bound training endpoint must be gated by ``pro_pack.require``.

SPLIT_BUNDLE.md: "Endpoints that need the Pro pack must call
``common.pro_pack.require()`` before doing any heavy work." On a Core-only
install the response is a structured ``412 pro_pack_required`` the Flutter
UI maps to the install dialog. These tests drive the FastAPI app with the
Pro pack reported absent and assert no endpoint gets past the gate.
"""

from __future__ import annotations

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from common import pro_pack

# (method, path, body) for every endpoint that imports torch/transformers/
# mlx or spawns a trainer. GET endpoints (adapters, runs, prompts) are Core.
PRO_ENDPOINTS: list[tuple[str, dict]] = [
    (
        "/training/create",
        {
            "adapter_name": "t",
            "base_model_id": "studiomc-4b",
            "source_type": "collection",
            "source_ref": "col-1",
        },
    ),
    (
        "/training/distill",
        {
            "student_model_id": "studiomc-4b",
            "teacher_model_id": "studiomc-4b",
            "dataset_text": "some text",
        },
    ),
    (
        "/training/context-distill",
        {"model_id": "studiomc-4b", "collection_id": "col-1"},
    ),
    ("/training/export/merge", {"adapter_id": "adapter-x"}),
    ("/training/export/gguf", {"adapter_id": "adapter-x"}),
    ("/training/export/safetensors", {"adapter_id": "adapter-x"}),
    (
        "/training/export/huggingface",
        {"adapter_id": "adapter-x", "repo_id": "org/repo", "token": "x"},
    ),
]


@pytest.fixture
def pro_pack_absent(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    absent = pro_pack.ProPackStatus(
        installed=False, version=None, python_path=None, needs_upgrade=False
    )
    monkeypatch.setattr(pro_pack, "get_status", lambda: absent)
    yield


@pytest.fixture
def client() -> Iterator[TestClient]:
    from training.app import app

    with TestClient(app, raise_server_exceptions=True) as c:
        yield c


@pytest.mark.parametrize(("path", "body"), PRO_ENDPOINTS, ids=[p for p, _ in PRO_ENDPOINTS])
def test_pro_endpoint_returns_412_without_pro_pack(
    pro_pack_absent: None, client: TestClient, path: str, body: dict
) -> None:
    response = client.post(path, json=body)
    assert response.status_code == 412, response.text
    payload = response.json()
    assert payload["error"] == "pro_pack_required"
    assert payload["feature"] == "training"
    assert payload["required_version"] == pro_pack.REQUIRED_PRO_VERSION
    assert payload["pro_pack"]["installed"] is False


def test_pro_endpoint_gate_runs_before_validation_side_effects(
    pro_pack_absent: None, client: TestClient
) -> None:
    """A malformed body still gets 412 before any DB or model work is attempted.

    FastAPI validates the body first (422 on bad shapes), so we send a
    valid shape with a nonexistent adapter: without the gate this would
    reach the filesystem and answer 404.
    """
    response = client.post("/training/export/merge", json={"adapter_id": "nope"})
    assert response.status_code == 412


def test_core_read_endpoints_stay_available_without_pro_pack(
    pro_pack_absent: None, client: TestClient
) -> None:
    """Listing adapters/runs is Core: it must not be gated."""
    assert client.get("/health").status_code == 200
    assert client.get("/training/prompts").status_code == 200


def test_require_passes_through_when_installed(monkeypatch: pytest.MonkeyPatch) -> None:
    present = pro_pack.ProPackStatus(
        installed=True,
        version=pro_pack.REQUIRED_PRO_VERSION,
        python_path="/x/bin/python",
        needs_upgrade=False,
    )
    monkeypatch.setattr(pro_pack, "get_status", lambda: present)
    assert pro_pack.require("training") is present

    stale = pro_pack.ProPackStatus(
        installed=True, version="0.0.1", python_path="/x/bin/python", needs_upgrade=True
    )
    monkeypatch.setattr(pro_pack, "get_status", lambda: stale)
    with pytest.raises(pro_pack.ProPackRequiredError):
        pro_pack.require("training")
