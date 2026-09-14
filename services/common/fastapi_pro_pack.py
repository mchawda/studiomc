# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""FastAPI exception handler for :class:`ProPackRequiredError`.

Every Studiomc child service installs this handler so that any code
path that raises ``ProPackRequiredError`` gets converted into a
standard ``412 Precondition Failed`` response with the structured
``pro_pack_required`` error code that the Flutter client knows how to
react to (it pops the install dialog instead of showing a generic
"500 something went wrong" toast).

Usage::

    from common.fastapi_pro_pack import install_pro_pack_handler

    app = FastAPI(...)
    install_pro_pack_handler(app)

The 412 envelope shape is the API contract documented in
``services/SPLIT_BUNDLE.md``; it must stay backward-compatible.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from common.pro_pack import REQUIRED_PRO_VERSION, ProPackRequiredError, get_status


def install_pro_pack_handler(app: FastAPI) -> None:
    """Register the global ``ProPackRequiredError`` handler on ``app``."""

    @app.exception_handler(ProPackRequiredError)
    async def _on_pro_pack_required(
        _request: Request, exc: ProPackRequiredError
    ) -> JSONResponse:
        status = get_status()
        return JSONResponse(
            status_code=412,
            content={
                "error": "pro_pack_required",
                "feature": exc.feature,
                "message": str(exc),
                "pro_pack": status.to_dict(),
                "required_version": REQUIRED_PRO_VERSION,
            },
        )
