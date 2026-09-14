# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""MCP broker: server registration, validation, and audit logging.

These tests cover the parts of :mod:`mcp.broker` that don't require an
actual MCP server subprocess — schema validation, CRUD, and the
catalogue write-through. The session lifecycle (which forks a real
process) is exercised in higher-level integration tests.
"""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from pathlib import Path

import pytest

from common import config as common_config
from common import database as common_database
from common.database import Database


@pytest.fixture
def isolated_db(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    db_file = tmp_path / "test.db"
    monkeypatch.setattr(common_config, "DB_PATH", db_file)
    monkeypatch.setattr(common_database, "DB_PATH", db_file)
    Database._instance = None  # type: ignore[attr-defined]
    # Force a fresh broker singleton so per-test state doesn't leak.
    from mcp.broker import MCPBroker

    MCPBroker._instance = None  # type: ignore[attr-defined]
    yield
    Database._instance = None  # type: ignore[attr-defined]
    MCPBroker._instance = None  # type: ignore[attr-defined]


def _run(coro):  # type: ignore[no-untyped-def]
    return asyncio.run(coro)


def test_add_stdio_server_requires_command(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        with pytest.raises(ValueError, match="stdio.*command"):
            await broker.add_server(
                name="bad",
                transport="stdio",
                command=None,
            )

    _run(go())


def test_add_http_server_requires_url(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        with pytest.raises(ValueError, match="url"):
            await broker.add_server(
                name="bad",
                transport="http",
                url=None,
            )

    _run(go())


def test_add_unsupported_transport_rejected(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        with pytest.raises(ValueError, match="unsupported transport"):
            await broker.add_server(
                name="bad",
                transport="grpc",  # not supported
                url="http://localhost",
            )

    _run(go())


def test_server_crud_roundtrip(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()

        spec = await broker.add_server(
            name="echo",
            transport="stdio",
            command="/usr/bin/cat",
            args=["-"],
            env={"FOO": "bar"},
            enabled=True,
            auto_start=False,
        )
        assert spec.id.startswith("mcp-")
        assert spec.name == "echo"
        assert spec.args == ["-"]
        assert spec.env == {"FOO": "bar"}
        assert spec.auto_start is False

        # Read back
        fetched = await broker.get_server(spec.id)
        assert fetched is not None
        assert fetched.name == "echo"

        # List
        servers = await broker.list_servers()
        assert len(servers) == 1

        # Update via whitelist
        updated = await broker.update_server(spec.id, name="echo-renamed")
        assert updated.name == "echo-renamed"

        # Update with unknown field is silently ignored (whitelist).
        updated2 = await broker.update_server(spec.id, totally_unknown_field="x")
        assert updated2.name == "echo-renamed"

        # Delete
        await broker.remove_server(spec.id)
        assert await broker.get_server(spec.id) is None

    _run(go())


def test_get_unknown_server_returns_none(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        assert await broker.get_server("mcp-nonexistent") is None

    _run(go())


def test_start_unknown_server_raises(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        with pytest.raises(KeyError):
            await broker.start("mcp-nope")

    _run(go())


def test_call_tool_records_audit_row_on_failure(
    isolated_db: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Even when a tool call blows up, the audit row must land.

    This is the core compliance requirement (enterprise platform rule
    #5: every action logged). We force a synthetic failure and then
    verify the row exists.
    """
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        spec = await broker.add_server(
            name="dummy",
            transport="stdio",
            command="/bin/true",
        )

        # Fake a session that raises on call_tool.
        class _FakeSession:
            is_alive = True

            async def call_tool(self, name: str, args: dict) -> dict:
                raise RuntimeError("synthetic failure")

        broker._sessions[spec.id] = _FakeSession()  # type: ignore[assignment]

        with pytest.raises(RuntimeError, match="synthetic"):
            await broker.call_tool(spec.id, "do_thing", {"x": 1})

        db = await Database.instance()
        rows = await db.fetchall(
            "SELECT * FROM mcp_audit WHERE server_id = ?", (spec.id,)
        )
        assert len(rows) == 1
        assert rows[0]["tool_name"] == "do_thing"
        assert rows[0]["error"] is not None
        assert "synthetic" in rows[0]["error"]
        # Duration must be a non-negative integer.
        assert rows[0]["duration_ms"] >= 0

    _run(go())


def test_list_all_tools_empty_when_no_servers(isolated_db: None) -> None:
    from mcp.broker import MCPBroker

    async def go() -> None:
        broker = MCPBroker.instance()
        assert await broker.list_all_tools() == []

    _run(go())
