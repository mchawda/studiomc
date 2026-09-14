# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc MCP service — Model Context Protocol server registry & broker.

The MCP service is a lightweight FastAPI app that:

* Persists user-registered MCP servers (stdio, http, sse transports).
* Spawns enabled stdio servers as managed subprocesses.
* Performs the JSON-RPC handshake (``initialize`` → ``tools/list``) and
  caches the discovered tool catalogue in SQLite.
* Exposes a single ``/v1/tools/call`` endpoint that the Studiomc
  orchestrator and inference service call to invoke any tool from any
  registered server.
* Audits every tool call (enterprise rule §5).

Runs on port 8108. Single-binary, talks to the shared ``app.sqlite``.
"""
