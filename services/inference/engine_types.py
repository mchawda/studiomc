# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Pure data types shared across the inference layer.

This module is intentionally torch-free so that the lightweight Core
bundle (no PyTorch, no transformers) can still type-check and ship
``GenerationMetrics``, ``EngineState`` and ``PROFILE_PARAMS`` to every
backend (Ollama, LM Studio, Frontier, llama-server) without dragging in
the Pro ML stack.

The heavy ``InferenceEngine`` class lives in ``inference.engine`` and is
only imported when the user opts into a SpliceLLM model (which requires
the Pro pack).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class GenerationMetrics:
    """Metrics collected during a single generation."""

    ttft_ms: int = 0          # time to first token
    tok_per_s: float = 0.0    # tokens per second
    total_tokens: int = 0
    prompt_tokens: int = 0
    completion_tokens: int = 0
    elapsed_ms: int = 0


@dataclass
class EngineState:
    """Tracks current engine state (used by SpliceLLM only)."""

    active_model_id: str | None = None
    active_model_path: str | None = None
    loaded: bool = False
    generating: bool = False


# Sampling profile presets — pure data, used by every backend.
PROFILE_PARAMS: dict[str, dict[str, float | int]] = {
    "fast": {
        "temperature": 0.5,
        "max_new_tokens": 256,
        "repetition_penalty": 1.1,
        "top_p": 0.85,
    },
    "balanced": {
        "temperature": 0.7,
        "max_new_tokens": 1024,
        "repetition_penalty": 1.15,
        "top_p": 0.9,
    },
    "quality": {
        "temperature": 0.8,
        "max_new_tokens": 2048,
        "repetition_penalty": 1.2,
        "top_p": 0.95,
    },
}
