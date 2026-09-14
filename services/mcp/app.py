# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc MCP Service — FastAPI entry point.

Runs on 127.0.0.1:8108 and is managed by the supervisor like any other
child service. On startup it auto-starts every enabled MCP server with
``auto_start = 1``; on shutdown it cleanly tears them all down so we
don't leak subprocesses.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from contextlib import asynccontextmanager  # noqa: E402
from typing import AsyncIterator  # noqa: E402

import uvicorn  # noqa: E402
from fastapi import FastAPI  # noqa: E402

from common.config import MCP_PORT, SERVICE_HOST, ensure_dirs  # noqa: E402
from common.database import Database  # noqa: E402
from mcp.broker import MCPBroker  # noqa: E402
from mcp.routes import router  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(name)-22s | %(levelname)-5s | %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("mcp")


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup/shutdown for the MCP service.

    Auto-starts every enabled MCP server on boot and cleanly shuts them
    down when the supervisor stops the service so we don't leak
    subprocesses.
    """
    ensure_dirs()
    await Database.instance()
    broker = MCPBroker.instance()
    await broker.autostart_all()
    logger.info("MCP service ready on %s:%d", SERVICE_HOST, MCP_PORT)
    try:
        yield
    finally:
        await MCPBroker.instance().shutdown_all()


app = FastAPI(
    title="Studiomc MCP Service",
    description=(
        "Manages the Model Context Protocol server registry and brokers "
        "tool calls between Studiomc and third-party MCP servers."
    ),
    version="0.1.0",
    lifespan=lifespan,
)
app.include_router(router)


if __name__ == "__main__":
    uvicorn.run(app, host=SERVICE_HOST, port=MCP_PORT, log_level="info")
