# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""App-wide configuration and path management.

Runtime layout (user machine):
~/.studiomc/
  db/app.sqlite
  models/<model_id>/blobs/...
  docs/<doc_id>/original.*, extracted.txt, chunks.jsonl
  indexes/<collection_id>/vectors.*
  logs/
  cache/downloads/
"""

from __future__ import annotations

import os
from pathlib import Path

from platformdirs import user_data_dir


def _studiomc_root() -> Path:
    """Return the root data directory, respecting STUDIOMC_HOME env override."""
    override = os.environ.get("STUDIOMC_HOME")
    if override:
        return Path(override)
    return Path(user_data_dir("studiomc", "studiomc"))


ROOT = _studiomc_root()
DB_DIR = ROOT / "db"
DB_PATH = DB_DIR / "app.sqlite"
MODELS_DIR = ROOT / "models"
DOCS_DIR = ROOT / "docs"
INDEXES_DIR = ROOT / "indexes"
LOGS_DIR = ROOT / "logs"
CACHE_DIR = ROOT / "cache"
DOWNLOADS_DIR = CACHE_DIR / "downloads"

# Service ports (all localhost-only)
INFERENCE_PORT = 8100
MODEL_MANAGER_PORT = 8101
DOCUMENT_PORT = 8102
CLARA_PORT = 8103
LRE_PORT = 8104
ORCHESTRATOR_PORT = 8105
SUPERVISOR_PORT = 8110
TRAINING_PORT = 8106

ALL_PORTS = {
    "inference": INFERENCE_PORT,
    "model_manager": MODEL_MANAGER_PORT,
    "documents": DOCUMENT_PORT,
    "clara": CLARA_PORT,
    "lre": LRE_PORT,
    "orchestrator": ORCHESTRATOR_PORT,
    "training": TRAINING_PORT,
    "supervisor": SUPERVISOR_PORT,
}


ADAPTERS_DIR = ROOT / "adapters"

def ensure_dirs() -> None:
    """Create all required directories on first launch."""
    for d in (DB_DIR, MODELS_DIR, DOCS_DIR, INDEXES_DIR, LOGS_DIR, CACHE_DIR, DOWNLOADS_DIR, ADAPTERS_DIR):
        d.mkdir(parents=True, exist_ok=True)
