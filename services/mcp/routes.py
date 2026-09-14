# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""HTTP API for the Studiomc MCP service.

All routes are versioned under ``/v1`` per enterprise rule §7.

* ``GET    /v1/servers``                 — list registered MCP servers
* ``POST   /v1/servers``                 — register a new server
* ``GET    /v1/servers/{id}``            — server detail
* ``PATCH  /v1/servers/{id}``            — edit server fields
* ``DELETE /v1/servers/{id}``            — remove server (stops it first)
* ``POST   /v1/servers/{id}/start``      — start + discover tools
* ``POST   /v1/servers/{id}/stop``       — stop the underlying process
* ``POST   /v1/servers/{id}/restart``    — full restart cycle
* ``GET    /v1/tools``                   — flat tool catalogue across servers
* ``POST   /v1/tools/call``              — invoke a tool
* ``GET    /v1/audit``                   — recent tool calls (audit trail)
"""

from __future__ import annotations

import json
import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field

from common.database import Database
from mcp.broker import MCPBroker
from mcp.client import MCPError

logger = logging.getLogger("mcp.routes")
router = APIRouter()


# ── Schemas ──────────────────────────────────────────────────────────


class ServerIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=120)
    description: Optional[str] = None
    transport: str = Field("stdio", pattern="^(stdio|http|sse)$")
    command: Optional[str] = None
    args: list[str] = Field(default_factory=list)
    env: dict[str, str] = Field(default_factory=dict)
    url: Optional[str] = None
    enabled: bool = True
    auto_start: bool = True


class ServerPatch(BaseModel):
    name: Optional[str] = None
    description: Optional[str] = None
    command: Optional[str] = None
    args: Optional[list[str]] = None
    env: Optional[dict[str, str]] = None
    url: Optional[str] = None
    enabled: Optional[bool] = None
    auto_start: Optional[bool] = None


class ServerOut(BaseModel):
    id: str
    name: str
    description: Optional[str]
    transport: str
    command: Optional[str]
    args: list[str]
    env: dict[str, str]
    url: Optional[str]
    enabled: bool
    auto_start: bool
    running: bool
    last_error: Optional[str] = None


class ToolCallIn(BaseModel):
    server_id: str
    tool_name: str
    arguments: dict[str, Any] = Field(default_factory=dict)
    chat_id: Optional[str] = None
    actor: Optional[str] = None


class ApiResponse(BaseModel):
    success: bool = True
    data: Any = None
    error: Optional[dict[str, Any]] = None


def ok(data: Any = None) -> ApiResponse:
    return ApiResponse(success=True, data=data, error=None)


def err(message: str, code: str = "internal_error", status_code: int = 400) -> HTTPException:
    return HTTPException(
        status_code=status_code,
        detail={"success": False, "data": None, "error": {"code": code, "message": message}},
    )


# ── Health ───────────────────────────────────────────────────────────


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "mcp"}


# ── Server CRUD ──────────────────────────────────────────────────────


def _spec_to_out(spec: Any, *, running: bool) -> ServerOut:
    return ServerOut(
        id=spec.id,
        name=spec.name,
        description=spec.description,
        transport=spec.transport,
        command=spec.command,
        args=spec.args,
        env=spec.env,
        url=spec.url,
        enabled=spec.enabled,
        auto_start=spec.auto_start,
        running=running,
        last_error=None,
    )


@router.get("/v1/servers", response_model=ApiResponse)
async def list_servers() -> ApiResponse:
    broker = MCPBroker.instance()
    specs = await broker.list_servers()
    live = broker.list_live_tools()
    return ok([_spec_to_out(s, running=s.id in live).model_dump() for s in specs])


@router.post("/v1/servers", response_model=ApiResponse)
async def add_server(payload: ServerIn) -> ApiResponse:
    broker = MCPBroker.instance()
    try:
        spec = await broker.add_server(
            name=payload.name,
            description=payload.description,
            transport=payload.transport,
            command=payload.command,
            args=payload.args,
            env=payload.env,
            url=payload.url,
            enabled=payload.enabled,
            auto_start=payload.auto_start,
        )
    except ValueError as exc:
        raise err(str(exc), "validation_error", 422) from exc
    if spec.enabled and spec.auto_start:
        # Best-effort autostart so the user gets immediate feedback.
        try:
            await broker.start(spec.id)
        except Exception as exc:
            logger.warning("Autostart failed for %s: %s", spec.name, exc)
    running = spec.id in broker.list_live_tools()
    return ok(_spec_to_out(spec, running=running).model_dump())


@router.get("/v1/servers/{server_id}", response_model=ApiResponse)
async def get_server(server_id: str) -> ApiResponse:
    broker = MCPBroker.instance()
    spec = await broker.get_server(server_id)
    if spec is None:
        raise err("server not found", "not_found", 404)
    running = server_id in broker.list_live_tools()
    return ok(_spec_to_out(spec, running=running).model_dump())


@router.patch("/v1/servers/{server_id}", response_model=ApiResponse)
async def patch_server(server_id: str, payload: ServerPatch) -> ApiResponse:
    broker = MCPBroker.instance()
    fields: dict[str, Any] = {}
    body = payload.model_dump(exclude_unset=True)
    for key, value in body.items():
        if key == "args":
            fields["args_json"] = json.dumps(value or [])
        elif key == "env":
            fields["env_json"] = json.dumps(value or {})
        elif key in {"enabled", "auto_start"}:
            fields[key] = int(bool(value))
        else:
            fields[key] = value
    try:
        spec = await broker.update_server(server_id, **fields)
    except KeyError as exc:
        raise err("server not found", "not_found", 404) from exc
    running = server_id in broker.list_live_tools()
    return ok(_spec_to_out(spec, running=running).model_dump())


@router.delete("/v1/servers/{server_id}", response_model=ApiResponse)
async def delete_server(server_id: str) -> ApiResponse:
    broker = MCPBroker.instance()
    try:
        await broker.remove_server(server_id)
    except KeyError as exc:
        raise err("server not found", "not_found", 404) from exc
    return ok({"id": server_id, "removed": True})


# ── Lifecycle ────────────────────────────────────────────────────────


@router.post("/v1/servers/{server_id}/start", response_model=ApiResponse)
async def start_server(server_id: str) -> ApiResponse:
    broker = MCPBroker.instance()
    try:
        tools = await broker.start(server_id)
    except KeyError as exc:
        raise err("server not found", "not_found", 404) from exc
    except MCPError as exc:
        raise err(exc.message, "mcp_error", 502) from exc
    return ok({
        "id": server_id,
        "running": True,
        "tool_count": len(tools),
        "tools": [
            {"name": t.name, "description": t.description, "input_schema": t.input_schema}
            for t in tools
        ],
    })


@router.post("/v1/servers/{server_id}/stop", response_model=ApiResponse)
async def stop_server(server_id: str) -> ApiResponse:
    broker = MCPBroker.instance()
    await broker.stop(server_id)
    return ok({"id": server_id, "running": False})


@router.post("/v1/servers/{server_id}/restart", response_model=ApiResponse)
async def restart_server(server_id: str) -> ApiResponse:
    broker = MCPBroker.instance()
    try:
        tools = await broker.restart(server_id)
    except KeyError as exc:
        raise err("server not found", "not_found", 404) from exc
    except MCPError as exc:
        raise err(exc.message, "mcp_error", 502) from exc
    return ok({"id": server_id, "running": True, "tool_count": len(tools)})


# ── Tools ────────────────────────────────────────────────────────────


@router.get("/v1/tools", response_model=ApiResponse)
async def list_tools() -> ApiResponse:
    broker = MCPBroker.instance()
    return ok(await broker.list_all_tools())


@router.post("/v1/tools/call", response_model=ApiResponse)
async def call_tool(payload: ToolCallIn) -> ApiResponse:
    broker = MCPBroker.instance()
    try:
        result = await broker.call_tool(
            payload.server_id,
            payload.tool_name,
            payload.arguments,
            chat_id=payload.chat_id,
            actor=payload.actor,
        )
    except KeyError as exc:
        raise err("server not found", "not_found", 404) from exc
    except MCPError as exc:
        raise err(exc.message, f"mcp_{exc.code}", 502) from exc
    return ok(result)


# ── Audit (enterprise rule §5) ───────────────────────────────────────


@router.get("/v1/audit", response_model=ApiResponse)
async def list_audit(
    limit: int = Query(50, ge=1, le=500),
    server_id: Optional[str] = Query(None),
) -> ApiResponse:
    db = await Database.instance()
    if server_id:
        rows = await db.fetchall(
            """
            SELECT id, server_id, tool_name, chat_id, actor, arguments_json,
                   result_summary, error, duration_ms, created_at
            FROM mcp_audit
            WHERE server_id = ?
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (server_id, limit),
        )
    else:
        rows = await db.fetchall(
            """
            SELECT id, server_id, tool_name, chat_id, actor, arguments_json,
                   result_summary, error, duration_ms, created_at
            FROM mcp_audit
            ORDER BY created_at DESC
            LIMIT ?
            """,
            (limit,),
        )
    out = []
    for r in rows:
        out.append({
            "id": r["id"],
            "server_id": r["server_id"],
            "tool_name": r["tool_name"],
            "chat_id": r["chat_id"],
            "actor": r["actor"],
            "arguments": json.loads(r["arguments_json"] or "{}"),
            "result_summary": r["result_summary"],
            "error": r["error"],
            "duration_ms": r["duration_ms"],
            "created_at": r["created_at"],
        })
    return ok(out)
