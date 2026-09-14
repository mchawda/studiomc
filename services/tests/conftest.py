# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Test-session isolation.

``common.config`` resolves the data directory once at import time from
``STUDIOMC_HOME`` (falling back to the user's real Application Support
folder). Importing service ``app`` modules in tests calls ``ensure_dirs()``
and opens log files, so point everything at a throwaway directory before
any service module is imported. Developers can still override by setting
``STUDIOMC_HOME`` themselves.
"""

from __future__ import annotations

import os
import tempfile

if not os.environ.get("STUDIOMC_HOME"):
    os.environ["STUDIOMC_HOME"] = tempfile.mkdtemp(prefix="studiomc-tests-")
