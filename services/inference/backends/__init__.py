# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Backend clients for the Inference Router.

Provides a unified interface for multiple LLM inference backends:
    - Ollama       (local, REST API at localhost:11434)
    - LM Studio    (local, OpenAI-compatible at localhost:1234)
    - Studiomc     (built-in SpliceLLM engine)
    - Frontier     (cloud, any OpenAI-compatible API)

Each backend implements the :class:`BackendClient` abstract base class.
"""

from __future__ import annotations

import abc
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from inference.engine import GenerationMetrics

logger = logging.getLogger("inference.backends")

# ── Constants ─────────────────────────────────────────────────────────

OLLAMA_DEFAULT_URL = "http://localhost:11434"
LMSTUDIO_DEFAULT_URL = "http://localhost:1234"
PROBE_TIMEOUT = 3.0  # seconds to wait when probing a backend


# ── Data classes ──────────────────────────────────────────────────────

@dataclass
class BackendInfo:
    """Metadata about a discovered backend."""

    name: str
    url: str | None = None
    online: bool = False
    models: list[dict[str, Any]] = field(default_factory=list)
    error: str | None = None


@dataclass
class UnifiedModel:
    """A model from any backend, presented with a unified schema."""

    id: str
    name: str
    backend: str  # "ollama", "lmstudio", "studiomc", "frontier:<provider>"
    backend_model_id: str  # the id used by the backend itself
    size_bytes: int | None = None
    params_billion: float | None = None
    quant: str | None = None
    arch: str | None = None
    context_length: int | None = None
    details: dict[str, Any] = field(default_factory=dict)


# ── Abstract backend client ──────────────────────────────────────────

class BackendClient(abc.ABC):
    """Base class for all inference backend clients.

    Every backend must implement:
        - probe()           — check availability and discover models
        - list_models()     — return models in UnifiedModel format
        - generate_stream() — streaming token generation
        - generate()        — non-streaming generation
        - close()           — cleanup resources
    """

    name: str = "unknown"

    @abc.abstractmethod
    async def probe(self) -> BackendInfo:
        """Check if the backend is available and list its models."""
        ...

    @abc.abstractmethod
    async def list_models(self) -> list[UnifiedModel]:
        """Return available models."""
        ...

    @abc.abstractmethod
    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Stream tokens as (token, metrics_or_none) tuples.

        The final yield should carry completed GenerationMetrics.
        """
        ...

    @abc.abstractmethod
    async def generate(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        """Non-streaming generation. Returns (text, metrics)."""
        ...

    async def close(self) -> None:
        """Release resources. Override if the backend holds connections."""
        pass


# ── Re-exports for convenient imports ─────────────────────────────────
# Usage: from inference.backends import OllamaClient, LMStudioClient, ...

from inference.backends.ollama import OllamaClient
from inference.backends.lmstudio import LMStudioClient
from inference.backends.studiomc import StudiomcClient
from inference.backends.frontier import FrontierClient

__all__ = [
    # Data classes
    "BackendInfo",
    "UnifiedModel",
    # Base
    "BackendClient",
    # Constants
    "OLLAMA_DEFAULT_URL",
    "LMSTUDIO_DEFAULT_URL",
    "PROBE_TIMEOUT",
    # Clients
    "OllamaClient",
    "LMStudioClient",
    "StudiomcClient",
    "FrontierClient",
]
