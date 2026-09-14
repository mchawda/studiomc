#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Repo-root wrapper for ``python -m training.studiomc_model``."""

from __future__ import annotations

import sys
from pathlib import Path

_SERVICES = Path(__file__).resolve().parents[2] / "services"
if str(_SERVICES) not in sys.path:
    sys.path.insert(0, str(_SERVICES))

from training.studiomc_model.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
