# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc backend client — wraps the built-in SpliceLLM InferenceEngine.

SpliceLLM runs large models by
streaming layers from disk. Unlike the other backends, this one is always
available (built-in). Models must be loaded explicitly via the model
manager before inference.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Any, AsyncIterator

# ── Path setup ────────────────────────────────────────────────────────
_SERVICES_DIR = str(Path(__file__).resolve().parent.parent.parent)
if _SERVICES_DIR not in sys.path:
    sys.path.insert(0, _SERVICES_DIR)

from inference.engine import GenerationMetrics, InferenceEngine
from inference.backends import BackendClient, BackendInfo, UnifiedModel

logger = logging.getLogger("inference.backends.studiomc")


class StudiomcClient(BackendClient):
    """Wraps the built-in SpliceLLM InferenceEngine.

    This backend is always "online" because it's compiled into the app.
    The model list only contains the currently loaded model (if any),
    since models must be downloaded and loaded via the model manager
    before they can be used.
    """

    name = "studiomc"

    def __init__(self, engine: InferenceEngine) -> None:
        self._engine = engine

    @property
    def engine(self) -> InferenceEngine:
        """Expose the underlying engine for direct access."""
        return self._engine

    # ── Discovery ─────────────────────────────────────────────────────

    async def probe(self) -> BackendInfo:
        """SpliceLLM engine is always online (built-in)."""
        models: list[dict[str, Any]] = []
        if self._engine.is_loaded and self._engine.active_model_id:
            models.append({"id": self._engine.active_model_id})
        return BackendInfo(
            name=self.name,
            url=None,
            online=True,  # always available
            models=models,
            error=None,
        )

    async def list_models(self) -> list[UnifiedModel]:
        """Return the currently loaded model (if any).

        SpliceLLM doesn't have a discoverable model catalog —
        models must be loaded via the model manager. We expose whatever
        is currently loaded so it appears in the unified model list.
        """
        models: list[UnifiedModel] = []
        if self._engine.is_loaded and self._engine.active_model_id:
            models.append(UnifiedModel(
                id=f"studiomc/{self._engine.active_model_id}",
                name=self._engine.active_model_id,
                backend="studiomc",
                backend_model_id=self._engine.active_model_id,
            ))
        return models

    # ── Generation ────────────────────────────────────────────────────

    async def generate_stream(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> AsyncIterator[tuple[str, GenerationMetrics | None]]:
        """Stream tokens from the SpliceLLM engine.

        Passes through profile, temperature, max_tokens, and slowmode
        to the underlying InferenceEngine.generate_stream().
        """
        profile = kwargs.get("profile", "balanced")
        temperature = kwargs.get("temperature")
        max_tokens = kwargs.get("max_tokens")
        slowmode = kwargs.get("slowmode", False)

        async for token, m in self._engine.generate_stream(
            messages,
            profile=profile,
            temperature=temperature,
            max_tokens=max_tokens,
            slowmode=slowmode,
        ):
            yield token, m

    async def generate(
        self,
        model_id: str,
        messages: list[dict[str, str]],
        **kwargs: Any,
    ) -> tuple[str, GenerationMetrics]:
        """Non-streaming generation via SpliceLLM."""
        profile = kwargs.get("profile", "balanced")
        temperature = kwargs.get("temperature")
        max_tokens = kwargs.get("max_tokens")

        return await self._engine.generate(
            messages,
            profile=profile,
            temperature=temperature,
            max_tokens=max_tokens,
        )

    # ── Model lifecycle ───────────────────────────────────────────────

    async def load_model(self, model_id: str, model_path: str) -> None:
        """Load a model into SpliceLLM."""
        await self._engine.load_model(model_id, model_path)

    # ── Lifecycle ─────────────────────────────────────────────────────

    async def close(self) -> None:
        """Unload the current model from the engine."""
        await self._engine.unload_model()
