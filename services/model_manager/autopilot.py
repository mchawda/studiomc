"""Autopilot — hardware-aware model recommendation engine.

Takes HardwareInfo and returns a ranked list of recommended models,
plus a "bigger but slower" overflow list.

Heuristic approach:
1. Filter models by memory feasibility
2. Score by predicted tok/s, quality tier, use-case fit
3. Apply penalties for slow disk, CPU-only large models
4. Boost models already loaded in an active backend (Ollama, LM Studio)
5. Return top 3 recommended + overflow "bigger slower" list
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Any

from common.schemas import (
    AutopilotResult,
    HardwareInfo,
    ModelRecommendation,
    SpeedRating,
)

from model_manager.registry import CURATED_MODELS, AIModel

logger = logging.getLogger("model_manager.autopilot")


# ── Heuristic constants ──

# Approximate tok/s per billion parameters on different hardware tiers.
# These are rough estimates for Q4_K_M quantized models.
_TOKS_PER_PARAM_B_GPU = 12.0     # tok/s per 1B params on decent GPU
_TOKS_PER_PARAM_B_CPU = 3.5      # tok/s per 1B params on CPU (Apple Silicon / fast x86)
_TOKS_PER_PARAM_B_CPU_SLOW = 1.8 # tok/s per 1B params on slower CPU

# TTFT heuristic: base ms + ms per billion params
_TTFT_BASE_GPU_MS = 200
_TTFT_BASE_CPU_MS = 800
_TTFT_PER_PARAM_B_GPU = 80
_TTFT_PER_PARAM_B_CPU = 350

# Memory overhead multiplier (model needs ~1.2x disk size in RAM/VRAM)
_MEMORY_OVERHEAD = 1.2

# Penalty thresholds
_SLOW_DISK_THRESHOLD_MBPS = 200.0  # Below this, apply disk penalty
_CPU_LARGE_MODEL_THRESHOLD_B = 10.0  # Above this on CPU = heavy penalty
_MIN_VIABLE_TOKS = 1.0  # Below 1 tok/s = avoid recommending


@dataclass
class _ScoredModel:
    """Internal scoring container."""
    model: AIModel
    predicted_tok_s: float
    predicted_ttft_ms: int
    speed_rating: SpeedRating
    score: float  # higher = better recommendation
    explanation: str
    on_gpu: bool


@dataclass
class BackendModelInfo:
    """Describes a model already loaded/available in a backend runtime."""
    model_name: str
    backend: str  # "ollama", "lmstudio", etc.
    loaded: bool = False  # True if the model is currently loaded/warm


def recommend(
    hw: HardwareInfo,
    user_intent: str | None = None,
    models: list[AIModel] | None = None,
    backend_models: list[BackendModelInfo] | None = None,
) -> AutopilotResult:
    """Run the Autopilot recommendation algorithm.

    Args:
        hw: Hardware profile from scan_hardware().
        user_intent: Optional hint like "coding", "chat", "writing".
        models: Model catalog to score. Defaults to CURATED_MODELS.
        backend_models: Models available/loaded in external backends
                        (Ollama, LM Studio). Gets a scoring boost.

    Returns:
        AutopilotResult with top 3 recommended + bigger_slower overflow.
    """
    catalog = models if models is not None else CURATED_MODELS
    _backend_names = _build_backend_lookup(backend_models)
    has_gpu = hw.vram_bytes is not None and hw.vram_bytes > 0
    available_vram = hw.vram_bytes or 0
    available_ram = hw.ram_bytes

    scored: list[_ScoredModel] = []

    for model in catalog:
        disk_bytes = model.disk_bytes or 0
        params_b = model.params_billion or 0.0
        memory_needed = int(disk_bytes * _MEMORY_OVERHEAD)

        # ── Step 1: Determine if model fits in GPU VRAM or RAM ──
        on_gpu = has_gpu and memory_needed <= available_vram
        fits_ram = memory_needed <= available_ram

        if not on_gpu and not fits_ram:
            # Model doesn't fit anywhere — skip entirely
            continue

        # ── Step 2: Predict tok/s and TTFT ──
        if on_gpu:
            tok_s = _TOKS_PER_PARAM_B_GPU * (1.0 / max(params_b, 0.1))
            # Scale by VRAM headroom (more headroom = better batching)
            vram_ratio = available_vram / max(memory_needed, 1)
            tok_s *= min(vram_ratio, 2.0)
            tok_s = max(tok_s, 0.1)

            ttft_ms = _TTFT_BASE_GPU_MS + int(_TTFT_PER_PARAM_B_GPU * params_b)
        else:
            # CPU inference
            base_rate = _TOKS_PER_PARAM_B_CPU if hw.cpu_cores >= 6 else _TOKS_PER_PARAM_B_CPU_SLOW
            tok_s = base_rate * (1.0 / max(params_b, 0.1))
            # Scale by core count (diminishing returns)
            core_factor = min(hw.cpu_cores / 8.0, 1.5)
            tok_s *= core_factor
            tok_s = max(tok_s, 0.05)

            ttft_ms = _TTFT_BASE_CPU_MS + int(_TTFT_PER_PARAM_B_CPU * params_b)

        # ── Step 3: Compute base score ──
        # Score components: speed (0-40), quality (0-30), use-case (0-20), penalties (negative)
        speed_score = min(tok_s * 4.0, 40.0)

        # Quality tier based on param count
        if params_b >= 65:
            quality_score = 30.0
        elif params_b >= 7:
            quality_score = 25.0
        elif params_b >= 3:
            quality_score = 18.0
        else:
            quality_score = 10.0

        # Use-case fit
        use_case_score = _use_case_bonus(model, user_intent)

        # ── Step 4: Apply penalties ──
        penalty = 0.0

        # Disk speed penalty
        if hw.disk_read_mbps > 0 and hw.disk_read_mbps < _SLOW_DISK_THRESHOLD_MBPS:
            disk_ratio = hw.disk_read_mbps / _SLOW_DISK_THRESHOLD_MBPS
            penalty += (1.0 - disk_ratio) * 10.0
            ttft_ms = int(ttft_ms * (1.5 - 0.5 * disk_ratio))

        # CPU-only large model penalty
        if not on_gpu and params_b >= _CPU_LARGE_MODEL_THRESHOLD_B:
            overshoot = params_b / _CPU_LARGE_MODEL_THRESHOLD_B
            penalty += overshoot * 15.0

        # ── Step 4b: Backend availability bonus ──
        backend_bonus = 0.0
        backend_info = _backend_names.get((model.name or "").lower())
        if backend_info is None:
            # Also try matching on id
            backend_info = _backend_names.get((model.id or "").lower())
        if backend_info:
            # Model is available in an external backend — big bonus
            backend_bonus = 15.0
            if backend_info.loaded:
                # Model is already warm/loaded — even bigger bonus (instant TTFT)
                backend_bonus = 25.0
                ttft_ms = min(ttft_ms, 500)  # warm model = fast first token
                tok_s *= 1.5  # warm models are often faster

        total_score = speed_score + quality_score + use_case_score + backend_bonus - penalty

        # ── Step 5: Determine speed rating ──
        speed_rating = _compute_speed_rating(tok_s, ttft_ms)

        # ── Step 6: Build explanation ──
        explanation = _build_explanation(
            model, tok_s, ttft_ms, speed_rating, on_gpu, params_b,
            backend_info=backend_info,
        )

        scored.append(_ScoredModel(
            model=model,
            predicted_tok_s=round(tok_s, 1),
            predicted_ttft_ms=ttft_ms,
            speed_rating=speed_rating,
            score=total_score,
            explanation=explanation,
            on_gpu=on_gpu,
        ))

    # ── Sort and partition ──
    scored.sort(key=lambda s: s.score, reverse=True)

    recommended: list[ModelRecommendation] = []
    bigger_slower: list[ModelRecommendation] = []

    for sm in scored:
        rec = ModelRecommendation(
            model_id=sm.model.id,
            name=sm.model.name,
            predicted_tok_per_s=sm.predicted_tok_s,
            predicted_ttft_ms=sm.predicted_ttft_ms,
            speed_rating=sm.speed_rating,
            explanation=sm.explanation,
            disk_bytes=sm.model.disk_bytes or 0,
            recommended=True,
        )

        if sm.predicted_tok_s < _MIN_VIABLE_TOKS:
            # Too slow — put in overflow
            rec.recommended = False
            bigger_slower.append(rec)
        elif len(recommended) < 3:
            recommended.append(rec)
        else:
            rec.recommended = False
            bigger_slower.append(rec)

    return AutopilotResult(
        hw_info=hw,
        recommended=recommended,
        bigger_slower=bigger_slower,
    )


# ── Helpers ──

def _use_case_bonus(model: AIModel, intent: str | None) -> float:
    """Return 0-20 bonus score based on user intent matching model strengths."""
    if not intent:
        return 10.0  # neutral

    intent = intent.lower()
    name = (model.name or "").lower()
    arch = (model.arch or "").lower()

    if intent in ("coding", "code", "programming"):
        if "phi" in name or "phi" in arch:
            return 20.0  # Phi excels at coding
        if "qwen" in name:
            return 16.0
        return 10.0

    if intent in ("chat", "conversation", "default"):
        if "llama" in name:
            return 18.0
        if "mistral" in name:
            return 16.0
        return 12.0

    if intent in ("writing", "creative"):
        if "mistral" in name:
            return 18.0
        if "llama" in name and (model.params_billion or 0) >= 7:
            return 16.0
        return 10.0

    if intent in ("multilingual", "translation"):
        if "qwen" in name:
            return 20.0
        return 8.0

    return 10.0


def _compute_speed_rating(tok_s: float, ttft_ms: int) -> SpeedRating:
    """Map predicted performance to a SpeedRating."""
    if tok_s >= 10 and ttft_ms <= 2500:
        return SpeedRating.fast
    if tok_s >= 4 and ttft_ms <= 5000:
        return SpeedRating.ok
    if tok_s >= 1 and ttft_ms <= 8000:
        return SpeedRating.slow
    return SpeedRating.painful


def _build_explanation(
    model: AIModel,
    tok_s: float,
    ttft_ms: int,
    rating: SpeedRating,
    on_gpu: bool,
    params_b: float,
    backend_info: BackendModelInfo | None = None,
) -> str:
    """Generate a plain-English explanation for the recommendation."""
    parts: list[str] = []

    # Model identity
    parts.append(f"{model.name}")

    # Backend availability
    if backend_info:
        if backend_info.loaded:
            parts.append(f"already loaded in {backend_info.backend} (instant start)")
        else:
            parts.append(f"available in {backend_info.backend}")
    elif on_gpu:
        parts.append("runs on your GPU")
    else:
        parts.append("runs on CPU")

    # Speed
    speed_desc = {
        SpeedRating.fast: "very responsive",
        SpeedRating.ok: "comfortable speed",
        SpeedRating.slow: "noticeable delays",
        SpeedRating.painful: "very slow — consider something smaller",
    }
    parts.append(speed_desc.get(rating, ""))

    # Size context
    disk_gb = (model.disk_bytes or 0) / (1024 ** 3)
    parts.append(f"~{disk_gb:.1f} GB download")

    return " — ".join(parts) + "."


def _build_backend_lookup(
    backend_models: list[BackendModelInfo] | None,
) -> dict[str, BackendModelInfo]:
    """Build a lowercase name -> BackendModelInfo lookup dict."""
    if not backend_models:
        return {}
    lookup: dict[str, BackendModelInfo] = {}
    for bm in backend_models:
        key = bm.model_name.lower()
        # Prefer loaded models over merely available ones
        existing = lookup.get(key)
        if existing is None or (bm.loaded and not existing.loaded):
            lookup[key] = bm
    return lookup
