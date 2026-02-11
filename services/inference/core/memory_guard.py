# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""OOM prevention — memory monitoring and pre-flight checks.

Provides a ``MemoryGuard`` that:
    - Estimates memory requirements before loading a model.
    - Runs a background monitoring coroutine that watches system RAM.
    - Triggers emergency unloads when memory pressure exceeds thresholds.
    - Suggests smaller model alternatives when the target would OOM.

Uses ``psutil`` for cross-platform memory introspection (already a
project dependency).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

import psutil

logger = logging.getLogger("inference.core.memory_guard")


# ── Constants ─────────────────────────────────────────────────────────

# Default thresholds (fraction of total system RAM)
DEFAULT_WARNING_THRESHOLD = 0.80   # warn at 80%
DEFAULT_CRITICAL_THRESHOLD = 0.90  # emergency unload at 90%

# Heuristic: bytes-per-parameter for common dtypes
_BYTES_PER_PARAM = {
    "float32": 4,
    "float16": 2,
    "bfloat16": 2,
    "int8": 1,
    "int4": 0.5,
    "mxfp4": 0.5,
}

# Default overhead multiplier (activations, KV cache, buffers)
_OVERHEAD_MULTIPLIER = 1.3


@dataclass
class MemorySnapshot:
    """Point-in-time memory reading."""

    total_bytes: int
    available_bytes: int
    used_bytes: int
    percent_used: float
    swap_used_bytes: int = 0
    gpu_used_bytes: int | None = None
    gpu_total_bytes: int | None = None
    timestamp: float = field(default_factory=time.time)

    @property
    def available_gb(self) -> float:
        return self.available_bytes / (1024 ** 3)

    @property
    def total_gb(self) -> float:
        return self.total_bytes / (1024 ** 3)


@dataclass
class PreflightResult:
    """Result of a memory preflight check."""

    can_load: bool
    estimated_bytes: int
    available_bytes: int
    headroom_bytes: int
    message: str
    suggestion: str | None = None

    @property
    def estimated_gb(self) -> float:
        return self.estimated_bytes / (1024 ** 3)

    @property
    def available_gb(self) -> float:
        return self.available_bytes / (1024 ** 3)

    def to_dict(self) -> dict:
        return {
            "can_load": self.can_load,
            "estimated_gb": round(self.estimated_gb, 2),
            "available_gb": round(self.available_gb, 2),
            "headroom_bytes": self.headroom_bytes,
            "message": self.message,
            "suggestion": self.suggestion,
        }


class MemoryGuard:
    """OOM prevention guard for the inference engine.

    Usage::

        guard = MemoryGuard()

        # Check before loading
        result = guard.preflight_check("/path/to/model")
        if not result.can_load:
            print(result.message)
            print(result.suggestion)

        # Start background monitoring
        guard.start_monitor(unload_callback=my_unload_fn)

        # ... later ...
        guard.stop_monitor()
    """

    def __init__(
        self,
        warning_threshold: float = DEFAULT_WARNING_THRESHOLD,
        critical_threshold: float = DEFAULT_CRITICAL_THRESHOLD,
        poll_interval_seconds: float = 5.0,
    ) -> None:
        self.warning_threshold = warning_threshold
        self.critical_threshold = critical_threshold
        self.poll_interval = poll_interval_seconds

        self._monitor_task: asyncio.Task | None = None
        self._unload_callback: Callable[[], None] | None = None
        self._emergency_triggered = False
        self._loaded_models: dict[str, int] = {}  # model_id -> estimated bytes

    # ── Snapshot ──────────────────────────────────────────────────────

    @staticmethod
    def snapshot() -> MemorySnapshot:
        """Take a point-in-time memory reading."""
        vm = psutil.virtual_memory()
        swap = psutil.swap_memory()

        gpu_used: int | None = None
        gpu_total: int | None = None

        try:
            import torch
            if torch.cuda.is_available():
                gpu_used = torch.cuda.memory_allocated()
                gpu_total = torch.cuda.get_device_properties(0).total_mem
        except (ImportError, RuntimeError):
            pass

        return MemorySnapshot(
            total_bytes=vm.total,
            available_bytes=vm.available,
            used_bytes=vm.used,
            percent_used=vm.percent,
            swap_used_bytes=swap.used,
            gpu_used_bytes=gpu_used,
            gpu_total_bytes=gpu_total,
        )

    # ── Model size estimation ────────────────────────────────────────

    @staticmethod
    def estimate_model_bytes(model_path: str) -> int:
        """Estimate memory needed to run a model from its on-disk files.

        Strategy:
            1. Sum the size of all safetensors / bin weight files.
               For SpliceLLM out-of-core, peak memory is ~1 layer,
               but we estimate the full size as a conservative upper bound
               for non-OOC backends (Ollama, LM Studio).
            2. Read config.json for parameter count and dtype hints.
            3. Apply overhead multiplier for activations + KV cache.
        """
        p = Path(model_path)

        # Approach 1: sum weight file sizes (most accurate)
        weight_size = 0
        for pattern in ("*.safetensors", "*.bin"):
            for f in p.glob(pattern):
                weight_size += f.stat().st_size

        if weight_size > 0:
            # Apply overhead multiplier (activations, KV cache, buffers)
            return int(weight_size * _OVERHEAD_MULTIPLIER)

        # Approach 2: read config.json for parameter count
        config_path = p / "config.json"
        if config_path.exists():
            try:
                with open(config_path) as f:
                    cfg = json.load(f)

                # Try to compute from architecture params
                hidden = cfg.get("hidden_size", 4096)
                layers = cfg.get("num_hidden_layers", 32)
                vocab = cfg.get("vocab_size", 32000)
                intermediate = cfg.get("intermediate_size", hidden * 4)

                # Rough param count: embeddings + layers + head
                params_per_layer = (
                    4 * hidden * hidden  # attention QKV + out
                    + 2 * hidden * intermediate  # FFN up + down
                    + 3 * hidden  # norms + biases
                )
                total_params = (
                    vocab * hidden  # embeddings
                    + layers * params_per_layer
                    + vocab * hidden  # lm_head
                )

                # Detect dtype
                dtype_str = str(cfg.get("torch_dtype", "bfloat16"))
                bpp = _BYTES_PER_PARAM.get(dtype_str, 2)

                return int(total_params * bpp * _OVERHEAD_MULTIPLIER)
            except (json.JSONDecodeError, OSError, KeyError):
                pass

        # Fallback: assume 4GB (conservative for small models)
        logger.warning("Could not estimate model size for %s, assuming 4GB", model_path)
        return 4 * 1024 ** 3

    @staticmethod
    def estimate_ooc_peak_bytes(model_path: str) -> int:
        """Estimate peak memory for SpliceLLM out-of-core inference.

        OOC only loads one layer at a time, so peak memory is:
            max(layer_file_size) + embeddings + norm + lm_head + overhead

        This is much less than the full model size.
        """
        p = Path(model_path)

        max_layer_size = 0
        non_layer_size = 0

        for sf in p.glob("*.safetensors"):
            name = sf.stem
            size = sf.stat().st_size

            if name.startswith("layers."):
                max_layer_size = max(max_layer_size, size)
            elif name in ("embed_tokens", "norm", "lm_head"):
                non_layer_size += size
            # Skip original shards
            elif name.startswith("model-") or name == "model":
                continue

        if max_layer_size == 0:
            # Not split yet — fall back to full estimate
            return MemoryGuard.estimate_model_bytes(model_path)

        # Peak: largest layer + non-layer components + overhead
        peak = int((max_layer_size + non_layer_size) * _OVERHEAD_MULTIPLIER)
        return peak

    # ── Preflight check ──────────────────────────────────────────────

    def preflight_check(
        self,
        model_path: str,
        use_ooc: bool = True,
    ) -> PreflightResult:
        """Check whether loading a model would cause OOM.

        Args:
            model_path: Path to the model directory.
            use_ooc:    If True, estimate using OOC peak memory (much lower).

        Returns:
            PreflightResult with go/no-go decision.
        """
        snap = self.snapshot()

        if use_ooc:
            estimated = self.estimate_ooc_peak_bytes(model_path)
        else:
            estimated = self.estimate_model_bytes(model_path)

        # Available memory after accounting for critical threshold buffer
        safe_available = snap.available_bytes - int(
            snap.total_bytes * (1 - self.critical_threshold)
        )
        safe_available = max(safe_available, 0)

        headroom = safe_available - estimated
        can_load = headroom > 0

        if can_load:
            message = (
                f"Model fits: needs ~{estimated / (1024**3):.1f} GB, "
                f"{safe_available / (1024**3):.1f} GB safely available"
            )
            suggestion = None
        else:
            shortfall = -headroom
            message = (
                f"Insufficient memory: model needs ~{estimated / (1024**3):.1f} GB, "
                f"only {safe_available / (1024**3):.1f} GB safely available "
                f"(short by {shortfall / (1024**3):.1f} GB)"
            )
            suggestion = self._suggest_alternative(estimated, safe_available)

        result = PreflightResult(
            can_load=can_load,
            estimated_bytes=estimated,
            available_bytes=safe_available,
            headroom_bytes=headroom,
            message=message,
            suggestion=suggestion,
        )

        logger.info(
            "Preflight check for %s: %s (est=%.1fGB, avail=%.1fGB, headroom=%.1fGB)",
            model_path,
            "GO" if can_load else "NO-GO",
            result.estimated_gb,
            result.available_gb,
            headroom / (1024 ** 3),
        )
        return result

    @staticmethod
    def _suggest_alternative(needed_bytes: int, available_bytes: int) -> str:
        """Suggest a smaller model when the target would OOM."""
        available_gb = available_bytes / (1024 ** 3)

        if available_gb >= 8:
            return (
                "Try a smaller model: 7B-class models typically need ~4-6GB. "
                "Recommended: llama3.2:latest, qwen2.5:7b, or mistral."
            )
        elif available_gb >= 4:
            return (
                "Memory is limited. Try a 3B-class model: llama3.2:latest (~2GB), "
                "or enable out-of-core inference which streams layers from disk."
            )
        elif available_gb >= 2:
            return (
                "Very limited memory. Only tiny models (<1B params) may fit. "
                "Close other applications to free RAM, or use a cloud backend."
            )
        else:
            return (
                "Critically low memory. Cannot load any model locally. "
                "Free system memory or use a cloud/frontier backend instead."
            )

    # ── Model tracking ───────────────────────────────────────────────

    def register_loaded_model(self, model_id: str, estimated_bytes: int) -> None:
        """Track a loaded model for LRU eviction."""
        self._loaded_models[model_id] = estimated_bytes
        logger.debug("Registered model %s (%d bytes)", model_id, estimated_bytes)

    def unregister_model(self, model_id: str) -> None:
        """Remove a model from tracking."""
        self._loaded_models.pop(model_id, None)

    def get_lru_model(self) -> str | None:
        """Return the least-recently-used model id, or None."""
        # Currently uses insertion order (dict preserves order in Python 3.7+).
        # The first key is the oldest / least-recently-used.
        if not self._loaded_models:
            return None
        return next(iter(self._loaded_models))

    # ── Background monitor ───────────────────────────────────────────

    def start_monitor(
        self,
        unload_callback: Callable[[], None] | None = None,
    ) -> None:
        """Start background memory monitoring.

        Args:
            unload_callback: Called when memory exceeds critical threshold.
                             Should unload the LRU model to free memory.
        """
        if self._monitor_task is not None and not self._monitor_task.done():
            logger.debug("Monitor already running")
            return

        self._unload_callback = unload_callback
        self._emergency_triggered = False
        self._monitor_task = asyncio.ensure_future(self._monitor_loop())
        logger.info(
            "Memory monitor started (warn=%.0f%%, critical=%.0f%%, poll=%.1fs)",
            self.warning_threshold * 100,
            self.critical_threshold * 100,
            self.poll_interval,
        )

    def stop_monitor(self) -> None:
        """Stop the background monitor."""
        if self._monitor_task is not None:
            self._monitor_task.cancel()
            self._monitor_task = None
        logger.info("Memory monitor stopped")

    async def _monitor_loop(self) -> None:
        """Background coroutine that polls memory usage."""
        while True:
            try:
                await asyncio.sleep(self.poll_interval)
                snap = self.snapshot()

                used_fraction = snap.percent_used / 100.0

                if used_fraction >= self.critical_threshold:
                    logger.error(
                        "CRITICAL memory pressure: %.1f%% used (%.1f GB / %.1f GB)",
                        snap.percent_used,
                        snap.used_bytes / (1024 ** 3),
                        snap.total_gb,
                    )
                    await self._emergency_unload()

                elif used_fraction >= self.warning_threshold:
                    logger.warning(
                        "High memory pressure: %.1f%% used (%.1f GB available)",
                        snap.percent_used,
                        snap.available_gb,
                    )
                    # Reset emergency flag if we drop below critical
                    self._emergency_triggered = False

                else:
                    self._emergency_triggered = False

            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error("Memory monitor error: %s", e)
                await asyncio.sleep(self.poll_interval * 2)

    async def _emergency_unload(self) -> None:
        """Emergency: unload the least-recently-used model."""
        if self._emergency_triggered:
            # Already tried this cycle — don't spam
            return

        self._emergency_triggered = True
        lru_model = self.get_lru_model()

        if lru_model and self._unload_callback:
            logger.warning(
                "Emergency unloading LRU model '%s' to reclaim memory", lru_model
            )
            try:
                self._unload_callback()
                self.unregister_model(lru_model)
            except Exception as e:
                logger.error("Emergency unload failed: %s", e)
        else:
            logger.warning(
                "No models to unload or no callback registered. "
                "System may become unstable."
            )

    # ── Reporting ────────────────────────────────────────────────────

    def status(self) -> dict:
        """Return current memory status as a dict."""
        snap = self.snapshot()
        return {
            "total_gb": round(snap.total_gb, 2),
            "available_gb": round(snap.available_gb, 2),
            "percent_used": round(snap.percent_used, 1),
            "swap_used_gb": round(snap.swap_used_bytes / (1024 ** 3), 2),
            "gpu_used_gb": (
                round(snap.gpu_used_bytes / (1024 ** 3), 2)
                if snap.gpu_used_bytes is not None else None
            ),
            "gpu_total_gb": (
                round(snap.gpu_total_bytes / (1024 ** 3), 2)
                if snap.gpu_total_bytes is not None else None
            ),
            "loaded_models": dict(self._loaded_models),
            "warning_threshold_pct": self.warning_threshold * 100,
            "critical_threshold_pct": self.critical_threshold * 100,
            "monitor_running": (
                self._monitor_task is not None and not self._monitor_task.done()
            ),
        }
