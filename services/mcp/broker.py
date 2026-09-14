# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""MCP broker — owns all live :class:`MCPSession` instances.

One :class:`MCPBroker` instance per process. Responsible for:

* Loading registered servers from the database at startup.
* Spawning enabled servers (``auto_start = 1``) lazily on first use.
* Keeping the in-memory tool catalogue in sync with the DB on every
  successful refresh.
* Serializing tool calls per-server (each MCPSession is single-conn).
* Recording an audit row for every tool invocation.

Thread-safe via a single lock around the session map; MCP tool calls
themselves run concurrently against different sessions.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass
from typing import Any

from common.database import Database
from mcp.client import (
    HTTPTransport,
    MCPError,
    MCPSession,
    MCPTool,
    StdioTransport,
)

logger = logging.getLogger("mcp.broker")


# ── Server descriptor ────────────────────────────────────────────────


@dataclass
class ServerSpec:
    id: str
    name: str
    description: str | None
    transport: str  # 'stdio' | 'http' | 'sse'
    command: str | None
    args: list[str]
    env: dict[str, str]
    url: str | None
    enabled: bool
    auto_start: bool

    @classmethod
    def from_row(cls, row: Any) -> ServerSpec:
        return cls(
            id=row["id"],
            name=row["name"],
            description=row["description"],
            transport=row["transport"],
            command=row["command"],
            args=json.loads(row["args_json"] or "[]"),
            env=json.loads(row["env_json"] or "{}"),
            url=row["url"],
            enabled=bool(row["enabled"]),
            auto_start=bool(row["auto_start"]),
        )


# ── Broker ───────────────────────────────────────────────────────────


class MCPBroker:
    _instance: MCPBroker | None = None

    def __init__(self) -> None:
        self._sessions: dict[str, MCPSession] = {}
        self._call_locks: dict[str, asyncio.Lock] = {}
        self._tool_catalogue: dict[str, list[MCPTool]] = {}
        self._lock = asyncio.Lock()

    @classmethod
    def instance(cls) -> MCPBroker:
        if cls._instance is None:
            cls._instance = MCPBroker()
        return cls._instance

    # ── Server CRUD ──────────────────────────────────────────────

    async def list_servers(self) -> list[ServerSpec]:
        db = await Database.instance()
        rows = await db.fetchall(
            "SELECT * FROM mcp_servers ORDER BY created_at ASC"
        )
        return [ServerSpec.from_row(r) for r in rows]

    async def get_server(self, server_id: str) -> ServerSpec | None:
        db = await Database.instance()
        row = await db.fetchone(
            "SELECT * FROM mcp_servers WHERE id = ?", (server_id,)
        )
        return ServerSpec.from_row(row) if row else None

    async def add_server(
        self,
        *,
        name: str,
        transport: str,
        description: str | None = None,
        command: str | None = None,
        args: list[str] | None = None,
        env: dict[str, str] | None = None,
        url: str | None = None,
        enabled: bool = True,
        auto_start: bool = True,
    ) -> ServerSpec:
        if transport not in {"stdio", "http", "sse"}:
            raise ValueError(f"unsupported transport: {transport}")
        if transport == "stdio" and not command:
            raise ValueError("stdio transport requires a command")
        if transport != "stdio" and not url:
            raise ValueError(f"{transport} transport requires a url")

        server_id = f"mcp-{uuid.uuid4().hex[:12]}"
        db = await Database.instance()
        await db.execute(
            """
            INSERT INTO mcp_servers
                (id, name, description, transport, command, args_json,
                 env_json, url, enabled, auto_start)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                server_id,
                name,
                description,
                transport,
                command,
                json.dumps(args or []),
                json.dumps(env or {}),
                url,
                int(enabled),
                int(auto_start),
            ),
        )
        await db.commit()
        spec = await self.get_server(server_id)
        assert spec is not None
        return spec

    async def update_server(self, server_id: str, **fields: Any) -> ServerSpec:
        if not fields:
            spec = await self.get_server(server_id)
            if spec is None:
                raise KeyError(server_id)
            return spec
        # Whitelist columns to prevent SQL injection via field names.
        allowed = {
            "name", "description", "transport", "command", "args_json",
            "env_json", "url", "enabled", "auto_start", "last_error",
            "last_started_at",
        }
        sets: list[str] = []
        params: list[Any] = []
        for k, v in fields.items():
            if k not in allowed:
                continue
            sets.append(f"{k} = ?")
            params.append(v)
        if not sets:
            spec = await self.get_server(server_id)
            assert spec is not None
            return spec
        params.append(server_id)
        db = await Database.instance()
        await db.execute(
            f"UPDATE mcp_servers SET {', '.join(sets)} WHERE id = ?",
            tuple(params),
        )
        await db.commit()
        spec = await self.get_server(server_id)
        if spec is None:
            raise KeyError(server_id)
        return spec

    async def remove_server(self, server_id: str) -> None:
        await self.stop(server_id)
        db = await Database.instance()
        await db.execute("DELETE FROM mcp_servers WHERE id = ?", (server_id,))
        await db.commit()

    # ── Session lifecycle ───────────────────────────────────────

    async def start(self, server_id: str) -> list[MCPTool]:
        """Spawn the server (if needed) and return its discovered tools."""
        spec = await self.get_server(server_id)
        if spec is None:
            raise KeyError(server_id)
        if not spec.enabled:
            raise MCPError(-32000, f"server {spec.name} is disabled")

        async with self._lock:
            if server_id in self._sessions and self._sessions[server_id].is_alive:
                return self._tool_catalogue.get(server_id, [])

            session = self._build_session(spec)
            try:
                await session.open()
                tools = await session.list_tools()
            except Exception as exc:
                try:
                    await session.close()
                except Exception:
                    pass
                await self._mark_error(server_id, str(exc))
                raise

            self._sessions[server_id] = session
            self._call_locks.setdefault(server_id, asyncio.Lock())
            self._tool_catalogue[server_id] = tools

        await self._sync_tools(server_id, tools)
        await self.update_server(
            server_id,
            last_started_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            last_error=None,
        )
        logger.info("MCP server %s started — %d tools", spec.name, len(tools))
        return tools

    async def stop(self, server_id: str) -> None:
        async with self._lock:
            session = self._sessions.pop(server_id, None)
            self._tool_catalogue.pop(server_id, None)
            self._call_locks.pop(server_id, None)
        if session is not None:
            try:
                await session.close()
            except Exception:
                logger.exception("Error closing MCP server %s", server_id)
        # Wipe cached tool rows.
        db = await Database.instance()
        await db.execute("DELETE FROM mcp_tools WHERE server_id = ?", (server_id,))
        await db.commit()

    async def restart(self, server_id: str) -> list[MCPTool]:
        await self.stop(server_id)
        return await self.start(server_id)

    async def shutdown_all(self) -> None:
        for sid in list(self._sessions):
            try:
                await self.stop(sid)
            except Exception:
                logger.exception("Error stopping MCP server %s", sid)

    async def autostart_all(self) -> None:
        for spec in await self.list_servers():
            if spec.enabled and spec.auto_start:
                try:
                    await self.start(spec.id)
                except Exception as exc:
                    logger.warning("MCP autostart failed for %s: %s", spec.name, exc)

    # ── Tool catalogue ──────────────────────────────────────────

    def list_live_tools(self) -> dict[str, list[MCPTool]]:
        return dict(self._tool_catalogue)

    async def list_all_tools(self) -> list[dict[str, Any]]:
        """Return the full tool catalogue from the DB (live + last-known)."""
        db = await Database.instance()
        rows = await db.fetchall(
            """
            SELECT t.server_id, s.name as server_name, t.name, t.description,
                   t.input_schema_json, s.enabled
            FROM mcp_tools t
            JOIN mcp_servers s ON s.id = t.server_id
            ORDER BY s.name, t.name
            """
        )
        return [
            {
                "server_id": r["server_id"],
                "server_name": r["server_name"],
                "name": r["name"],
                "description": r["description"],
                "input_schema": json.loads(r["input_schema_json"] or "{}"),
                "enabled": bool(r["enabled"]),
            }
            for r in rows
        ]

    async def call_tool(
        self,
        server_id: str,
        tool_name: str,
        arguments: dict[str, Any] | None = None,
        *,
        chat_id: str | None = None,
        actor: str | None = None,
    ) -> dict[str, Any]:
        """Invoke a tool, ensuring the server is up. Audited."""
        if server_id not in self._sessions or not self._sessions[server_id].is_alive:
            await self.start(server_id)

        session = self._sessions[server_id]
        lock = self._call_locks.setdefault(server_id, asyncio.Lock())

        start = time.perf_counter()
        error: str | None = None
        result: dict[str, Any] = {}
        try:
            async with lock:
                result = await session.call_tool(tool_name, arguments or {})
        except MCPError as exc:
            error = f"mcp:{exc.code}:{exc.message}"
            raise
        except Exception as exc:
            error = f"exception:{type(exc).__name__}:{exc}"
            raise
        finally:
            duration_ms = int((time.perf_counter() - start) * 1000)
            await self._audit(
                server_id=server_id,
                tool_name=tool_name,
                arguments=arguments or {},
                chat_id=chat_id,
                actor=actor,
                result=result,
                error=error,
                duration_ms=duration_ms,
            )
        return result

    # ── Internals ───────────────────────────────────────────────

    @staticmethod
    def _build_session(spec: ServerSpec) -> MCPSession:
        if spec.transport == "stdio":
            assert spec.command is not None
            return MCPSession(
                StdioTransport(
                    command=spec.command,
                    args=list(spec.args),
                    env=dict(spec.env),
                )
            )
        if spec.transport in {"http", "sse"}:
            assert spec.url is not None
            # SSE-specific framing isn't widely implemented in real MCP
            # servers yet — fall back to plain HTTP JSON-RPC.
            return MCPSession(HTTPTransport(spec.url))
        raise MCPError(-32000, f"unsupported transport {spec.transport}")

    async def _sync_tools(self, server_id: str, tools: list[MCPTool]) -> None:
        db = await Database.instance()
        await db.execute("DELETE FROM mcp_tools WHERE server_id = ?", (server_id,))
        if tools:
            await db.executemany(
                """
                INSERT INTO mcp_tools (server_id, name, description, input_schema_json)
                VALUES (?, ?, ?, ?)
                """,
                [
                    (
                        server_id,
                        t.name,
                        t.description,
                        json.dumps(t.input_schema),
                    )
                    for t in tools
                ],
            )
        await db.commit()

    async def _mark_error(self, server_id: str, message: str) -> None:
        try:
            await self.update_server(server_id, last_error=message[:500])
        except Exception:
            logger.exception("Failed to record MCP error for %s", server_id)

    async def _audit(
        self,
        *,
        server_id: str,
        tool_name: str,
        arguments: dict[str, Any],
        chat_id: str | None,
        actor: str | None,
        result: dict[str, Any],
        error: str | None,
        duration_ms: int,
    ) -> None:
        try:
            db = await Database.instance()
            summary = json.dumps(result)[:500] if result else None
            await db.execute(
                """
                INSERT INTO mcp_audit
                    (server_id, tool_name, chat_id, actor, arguments_json,
                     result_summary, error, duration_ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    server_id,
                    tool_name,
                    chat_id,
                    actor,
                    json.dumps(arguments)[:2000],
                    summary,
                    error,
                    duration_ms,
                ),
            )
            await db.commit()
        except Exception:
            logger.exception("Audit write failed for %s/%s", server_id, tool_name)
