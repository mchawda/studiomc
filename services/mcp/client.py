# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Minimal Model Context Protocol (MCP) JSON-RPC client.

We deliberately avoid the official ``mcp`` SDK in the Core bundle to
keep the Python footprint tiny — the real MCP SDK pulls anyio + many
typing dependencies. This module ships only what we need:

* Bidirectional stdio JSON-RPC for ``stdio`` transport servers.
* Plain HTTP POST for ``http`` transport servers.
* SSE-over-HTTP for ``sse`` transport servers (server pushes events).

Every transport implements :class:`MCPTransport` so the broker can treat
them uniformly. JSON-RPC framing is per the MCP spec
(https://spec.modelcontextprotocol.io/) — Content-Length headers for
stdio, plain JSON bodies for http, ``event: message\\ndata: {...}``
frames for SSE.

This client is safe to import from the Core bundle: zero deps beyond
``httpx`` and the standard library.
"""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import logging
import os
import signal
import sys
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any

import httpx

logger = logging.getLogger("mcp.client")

# Default request timeout — generous because MCP servers may shell out.
DEFAULT_TIMEOUT = 30.0

# Cap stderr/stdout we log per server to avoid runaway memory use on
# misbehaving servers. Older lines are dropped.
LOG_TAIL_LINES = 200


class MCPError(RuntimeError):
    """Wraps a JSON-RPC error response from an MCP server."""

    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(f"MCP error {code}: {message}")
        self.code = code
        self.message = message
        self.data = data


# ── Transports ───────────────────────────────────────────────────────


class MCPTransport(ABC):
    """One concrete connection to a running MCP server."""

    @abstractmethod
    async def start(self) -> None: ...

    @abstractmethod
    async def stop(self) -> None: ...

    @abstractmethod
    async def request(self, method: str, params: dict | None = None) -> Any: ...

    @abstractmethod
    async def notify(self, method: str, params: dict | None = None) -> None: ...

    @property
    @abstractmethod
    def is_alive(self) -> bool: ...

    @property
    def stderr_tail(self) -> list[str]:
        """Most recent stderr lines (best-effort, may be empty)."""
        return []


@dataclass
class _PendingRequest:
    future: asyncio.Future[Any] = field(default_factory=asyncio.Future)


class StdioTransport(MCPTransport):
    """Standard MCP transport: spawn a subprocess, talk JSON-RPC over stdio.

    The MCP framing is one JSON object per line (newline-delimited),
    not the LSP-style Content-Length framing. Most reference servers
    (`@modelcontextprotocol/server-*`) follow this convention.
    """

    def __init__(
        self,
        command: str,
        args: list[str],
        env: dict[str, str] | None = None,
        cwd: str | None = None,
    ) -> None:
        self._command = command
        self._args = args
        self._env = env
        self._cwd = cwd
        self._proc: asyncio.subprocess.Process | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._stderr_task: asyncio.Task[None] | None = None
        self._pending: dict[int, _PendingRequest] = {}
        self._next_id = itertools.count(1)
        self._stderr_lines: list[str] = []
        self._lock = asyncio.Lock()

    @property
    def is_alive(self) -> bool:
        return self._proc is not None and self._proc.returncode is None

    @property
    def stderr_tail(self) -> list[str]:
        return list(self._stderr_lines)

    async def start(self) -> None:
        if self.is_alive:
            return
        env = os.environ.copy()
        if self._env:
            env.update(self._env)
        try:
            self._proc = await asyncio.create_subprocess_exec(
                self._command,
                *self._args,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env=env,
                cwd=self._cwd,
                preexec_fn=os.setsid if sys.platform != "win32" else None,
            )
        except FileNotFoundError as exc:
            raise MCPError(-32000, f"command not found: {self._command}") from exc

        self._reader_task = asyncio.create_task(self._read_stdout())
        self._stderr_task = asyncio.create_task(self._read_stderr())

    async def stop(self) -> None:
        if self._reader_task:
            self._reader_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._reader_task
        if self._stderr_task:
            self._stderr_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._stderr_task

        if self._proc and self._proc.returncode is None:
            try:
                if sys.platform != "win32":
                    os.killpg(os.getpgid(self._proc.pid), signal.SIGTERM)
                else:
                    self._proc.terminate()
            except (ProcessLookupError, OSError):
                pass
            try:
                await asyncio.wait_for(self._proc.wait(), timeout=3.0)
            except asyncio.TimeoutError:
                with contextlib.suppress(ProcessLookupError, OSError):
                    if sys.platform != "win32":
                        os.killpg(os.getpgid(self._proc.pid), signal.SIGKILL)
                    else:
                        self._proc.kill()

        # Fail any pending requests.
        for pending in self._pending.values():
            if not pending.future.done():
                pending.future.set_exception(MCPError(-32000, "transport closed"))
        self._pending.clear()
        self._proc = None

    async def request(self, method: str, params: dict | None = None) -> Any:
        if not self.is_alive or self._proc is None or self._proc.stdin is None:
            raise MCPError(-32000, "stdio transport not running")
        rpc_id = next(self._next_id)
        pending = _PendingRequest()
        self._pending[rpc_id] = pending

        payload: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": rpc_id,
            "method": method,
        }
        if params is not None:
            payload["params"] = params

        async with self._lock:
            self._proc.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
            await self._proc.stdin.drain()

        try:
            return await asyncio.wait_for(pending.future, timeout=DEFAULT_TIMEOUT)
        finally:
            self._pending.pop(rpc_id, None)

    async def notify(self, method: str, params: dict | None = None) -> None:
        if not self.is_alive or self._proc is None or self._proc.stdin is None:
            raise MCPError(-32000, "stdio transport not running")
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        async with self._lock:
            self._proc.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
            await self._proc.stdin.drain()

    async def _read_stdout(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        try:
            while not self._proc.stdout.at_eof():
                line = await self._proc.stdout.readline()
                if not line:
                    break
                line_str = line.decode("utf-8", errors="replace").strip()
                if not line_str:
                    continue
                try:
                    msg = json.loads(line_str)
                except json.JSONDecodeError:
                    logger.debug("Non-JSON stdout from MCP server: %s", line_str)
                    continue
                self._dispatch(msg)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("MCP stdout reader crashed")

    async def _read_stderr(self) -> None:
        assert self._proc is not None and self._proc.stderr is not None
        try:
            while not self._proc.stderr.at_eof():
                line = await self._proc.stderr.readline()
                if not line:
                    break
                line_str = line.decode("utf-8", errors="replace").rstrip()
                if not line_str:
                    continue
                self._stderr_lines.append(line_str)
                if len(self._stderr_lines) > LOG_TAIL_LINES:
                    self._stderr_lines = self._stderr_lines[-LOG_TAIL_LINES:]
                logger.debug("[mcp stderr] %s", line_str)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("MCP stderr reader crashed")

    def _dispatch(self, msg: dict[str, Any]) -> None:
        if "id" not in msg:
            # Notification from server — we don't currently subscribe.
            return
        pending = self._pending.get(msg["id"])
        if pending is None or pending.future.done():
            return
        if "error" in msg:
            err = msg["error"]
            pending.future.set_exception(
                MCPError(
                    int(err.get("code", -32000)),
                    str(err.get("message", "unknown error")),
                    err.get("data"),
                )
            )
        else:
            pending.future.set_result(msg.get("result"))


class HTTPTransport(MCPTransport):
    """Stateless MCP-over-HTTP transport.

    Each ``request()`` POSTs a JSON-RPC envelope to ``url`` and waits
    for the response body. ``notify()`` posts and ignores the body.
    """

    def __init__(self, url: str, headers: dict[str, str] | None = None) -> None:
        self._url = url
        self._headers = {"Content-Type": "application/json", **(headers or {})}
        self._client: httpx.AsyncClient | None = None
        self._next_id = itertools.count(1)
        self._alive = False

    @property
    def is_alive(self) -> bool:
        return self._alive and self._client is not None

    async def start(self) -> None:
        if self._client is None:
            self._client = httpx.AsyncClient(
                timeout=DEFAULT_TIMEOUT, headers=self._headers
            )
        self._alive = True

    async def stop(self) -> None:
        self._alive = False
        if self._client is not None:
            await self._client.aclose()
            self._client = None

    async def request(self, method: str, params: dict | None = None) -> Any:
        if self._client is None:
            raise MCPError(-32000, "http transport not started")
        payload: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": next(self._next_id),
            "method": method,
        }
        if params is not None:
            payload["params"] = params
        try:
            resp = await self._client.post(self._url, json=payload)
            resp.raise_for_status()
        except httpx.HTTPError as exc:
            raise MCPError(-32000, f"http transport error: {exc}") from exc
        body = resp.json()
        if "error" in body:
            err = body["error"]
            raise MCPError(
                int(err.get("code", -32000)),
                str(err.get("message", "unknown error")),
                err.get("data"),
            )
        return body.get("result")

    async def notify(self, method: str, params: dict | None = None) -> None:
        if self._client is None:
            return
        payload: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        with contextlib.suppress(httpx.HTTPError):
            await self._client.post(self._url, json=payload)


# ── High-level MCP session ────────────────────────────────────────────


CLIENT_INFO = {"name": "studiomc", "version": "0.1.0"}
PROTOCOL_VERSION = "2025-03-26"


@dataclass
class MCPTool:
    name: str
    description: str
    input_schema: dict[str, Any]


class MCPSession:
    """High-level wrapper around an :class:`MCPTransport`.

    Handles ``initialize`` handshake, tool discovery, tool invocation,
    and graceful teardown.
    """

    def __init__(self, transport: MCPTransport) -> None:
        self.transport = transport
        self._initialized = False
        self.server_info: dict[str, Any] = {}
        self.capabilities: dict[str, Any] = {}

    @property
    def is_alive(self) -> bool:
        return self.transport.is_alive and self._initialized

    async def open(self) -> None:
        await self.transport.start()
        result = await self.transport.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "clientInfo": CLIENT_INFO,
                "capabilities": {"tools": {}},
            },
        )
        self.server_info = (result or {}).get("serverInfo", {})
        self.capabilities = (result or {}).get("capabilities", {})
        # Per MCP: send the initialized notification before any other
        # request. Some servers refuse tools/list until we do.
        await self.transport.notify("notifications/initialized")
        self._initialized = True

    async def close(self) -> None:
        self._initialized = False
        await self.transport.stop()

    async def list_tools(self) -> list[MCPTool]:
        if not self._initialized:
            raise MCPError(-32000, "session not initialized")
        result = await self.transport.request("tools/list")
        out: list[MCPTool] = []
        for tool in (result or {}).get("tools", []):
            out.append(
                MCPTool(
                    name=str(tool.get("name") or ""),
                    description=str(tool.get("description") or ""),
                    input_schema=tool.get("inputSchema") or {},
                )
            )
        return out

    async def call_tool(
        self, name: str, arguments: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        if not self._initialized:
            raise MCPError(-32000, "session not initialized")
        return await self.transport.request(
            "tools/call",
            {"name": name, "arguments": arguments or {}},
        )
