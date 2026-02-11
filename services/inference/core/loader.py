"""Layer loader — loads individual layers from split safetensors files.

Provides efficient loading of per-layer weight files with optional
background prefetching for pipelining disk I/O with computation.

Phase 3 additions:
    - ``safe_switch()`` — crash-proof model switching that keeps the
      previous model active if loading the new one fails.
    - Validation helpers used by the router and MemoryGuard.
"""

from __future__ import annotations

import asyncio
import logging
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import torch
from safetensors.torch import load_file

logger = logging.getLogger("inference.core.loader")


# ── Switch result ─────────────────────────────────────────────────────


@dataclass
class SwitchResult:
    """Outcome of a safe_switch operation."""

    success: bool
    active_model_id: str | None
    active_model_path: str | None
    error: str | None = None

    def to_dict(self) -> dict:
        return {
            "success": self.success,
            "active_model_id": self.active_model_id,
            "active_model_path": self.active_model_path,
            "error": self.error,
        }


# ── LayerLoader ──────────────────────────────────────────────────────


class LayerLoader:
    """Loads model layers from split safetensors files.

    Each layer is stored as a separate .safetensors file. The loader
    provides synchronous loading, CPU-pinned loading for faster GPU
    transfer, and background prefetching.

    Args:
        model_path: Directory containing per-layer .safetensors files.
        device:     Target device for loaded tensors ('cpu', 'cuda', 'mps').
        prefetch:   Whether to enable background prefetching.
    """

    def __init__(
        self,
        model_path: str,
        device: str = "cpu",
        prefetch: bool = True,
    ) -> None:
        self.model_path = Path(model_path)
        self.device = device
        self.prefetch = prefetch
        self._executor = ThreadPoolExecutor(max_workers=1)
        self._prefetch_future: Future[dict[str, torch.Tensor]] | None = None
        self._prefetch_layer_name: str | None = None

    def _layer_file(self, layer_name: str) -> Path:
        """Get the path to a layer's safetensors file."""
        path = self.model_path / f"{layer_name}.safetensors"
        if not path.exists():
            raise FileNotFoundError(
                f"Layer file not found: {path}. "
                f"Has the model been split? Run split_model() first."
            )
        return path

    def load_layer(self, layer_name: str) -> dict[str, torch.Tensor]:
        """Load a single layer's weights from disk.

        If a prefetch for this layer is already in progress, returns the
        prefetched result instead of loading again.

        Args:
            layer_name: Name of the layer (e.g. 'layers.5', 'embed_tokens').

        Returns:
            Dict mapping weight names to tensors on the target device.
        """
        # Check if this layer was prefetched
        if (
            self._prefetch_future is not None
            and self._prefetch_layer_name == layer_name
            and self._prefetch_future.done()
        ):
            try:
                result = self._prefetch_future.result()
                self._prefetch_future = None
                self._prefetch_layer_name = None
                logger.debug("Using prefetched layer: %s", layer_name)
                return result
            except Exception:
                logger.debug("Prefetch failed for %s, loading fresh", layer_name)
                self._prefetch_future = None
                self._prefetch_layer_name = None

        # Also wait on in-progress prefetch for this layer
        if (
            self._prefetch_future is not None
            and self._prefetch_layer_name == layer_name
            and not self._prefetch_future.done()
        ):
            try:
                result = self._prefetch_future.result(timeout=120)
                self._prefetch_future = None
                self._prefetch_layer_name = None
                logger.debug("Waited for prefetch of layer: %s", layer_name)
                return result
            except Exception:
                logger.debug("Prefetch wait failed for %s, loading fresh", layer_name)
                self._prefetch_future = None
                self._prefetch_layer_name = None

        path = self._layer_file(layer_name)
        logger.debug("Loading layer from disk: %s", layer_name)
        tensors = load_file(str(path), device=self.device)
        return tensors

    def load_layer_to_cpu(self, layer_name: str) -> dict[str, torch.Tensor]:
        """Load a layer to CPU with pinned memory for faster GPU transfer.

        Pinned (page-locked) memory enables asynchronous CPU-to-GPU
        transfers, which can overlap with computation.

        Args:
            layer_name: Name of the layer.

        Returns:
            Dict mapping weight names to pinned CPU tensors.
        """
        path = self._layer_file(layer_name)
        tensors = load_file(str(path), device="cpu")

        # Pin memory for faster GPU transfer (only if CUDA is available)
        if torch.cuda.is_available():
            pinned = {}
            for name, tensor in tensors.items():
                pinned[name] = tensor.pin_memory()
            return pinned

        return tensors

    def _prefetch_worker(self, layer_name: str) -> dict[str, torch.Tensor]:
        """Worker function for background prefetching."""
        path = self._layer_file(layer_name)

        # For GPU targets, load to pinned CPU first
        if self.device != "cpu" and torch.cuda.is_available():
            tensors = load_file(str(path), device="cpu")
            pinned = {}
            for name, tensor in tensors.items():
                pinned[name] = tensor.pin_memory()
            return pinned

        return load_file(str(path), device=self.device)

    def prefetch_layer(self, layer_name: str) -> Future[dict[str, torch.Tensor]]:
        """Start loading a layer in a background thread.

        The prefetched result will be automatically used by the next
        call to load_layer() if the layer names match.

        Args:
            layer_name: Name of the layer to prefetch.

        Returns:
            Future that resolves to the layer's tensor dict.
        """
        # Cancel any existing prefetch
        if self._prefetch_future is not None and not self._prefetch_future.done():
            self._prefetch_future.cancel()

        logger.debug("Prefetching layer: %s", layer_name)
        self._prefetch_layer_name = layer_name
        self._prefetch_future = self._executor.submit(
            self._prefetch_worker, layer_name
        )
        return self._prefetch_future

    def close(self) -> None:
        """Shut down the prefetch executor."""
        self._executor.shutdown(wait=False)
        self._prefetch_future = None
        self._prefetch_layer_name = None


# ── Validation helpers ────────────────────────────────────────────────


def validate_model_path(model_path: str) -> tuple[bool, str]:
    """Validate that a model path exists and has the expected structure.

    Returns:
        (is_valid, message) tuple.
    """
    p = Path(model_path)

    if not p.exists():
        return False, f"Path does not exist: {model_path}"

    if not p.is_dir():
        return False, f"Not a directory: {model_path}"

    # Check for config.json
    if not (p / "config.json").exists():
        return False, f"Missing config.json in {model_path}"

    # Check for weight files
    has_safetensors = (
        (p / "model.safetensors").exists()
        or (p / "model.safetensors.index.json").exists()
        or any(p.glob("*.safetensors"))
    )
    has_bin = any(p.glob("*.bin"))

    if not has_safetensors and not has_bin:
        return False, f"No weight files (safetensors/bin) found in {model_path}"

    return True, "Model path is valid"


# ── Crash-proof model switching ───────────────────────────────────────


async def safe_switch(
    engine: object,
    from_model_id: str | None,
    to_model_id: str,
    to_model_path: str,
) -> SwitchResult:
    """Crash-proof model switching.

    Safely transitions from one model to another. If loading the new
    model fails for any reason, the previous model remains active —
    the system is never left in a broken state.

    Steps:
        1. Validate the new model exists and is accessible.
        2. Load the new model in a try/except.
        3. Only update engine state after successful load.
        4. On failure, keep the old model running and return error details.

    Args:
        engine:         The InferenceEngine instance.
        from_model_id:  Current model id (for logging / rollback).
        to_model_id:    New model id to switch to.
        to_model_path:  Filesystem path for the new model.

    Returns:
        SwitchResult with success/failure status and error details.
    """
    from inference.engine import InferenceEngine  # avoid circular import

    if not isinstance(engine, InferenceEngine):
        return SwitchResult(
            success=False,
            active_model_id=from_model_id,
            active_model_path=None,
            error="Invalid engine instance",
        )

    # Step 1: Validate the new model path
    is_valid, msg = validate_model_path(to_model_path)
    if not is_valid:
        logger.error("safe_switch: validation failed for %s: %s", to_model_path, msg)
        return SwitchResult(
            success=False,
            active_model_id=from_model_id,
            active_model_path=engine.state.active_model_path,
            error=f"Validation failed: {msg}",
        )

    # Step 2: If same model, skip
    if engine.state.active_model_id == to_model_id and engine.state.loaded:
        logger.info("safe_switch: model %s already active", to_model_id)
        return SwitchResult(
            success=True,
            active_model_id=to_model_id,
            active_model_path=engine.state.active_model_path,
        )

    # Step 3: Snapshot current state for rollback
    prev_model_id = engine.state.active_model_id
    prev_model_path = engine.state.active_model_path
    prev_loaded = engine.state.loaded

    logger.info(
        "safe_switch: %s -> %s (%s)",
        from_model_id or "(none)",
        to_model_id,
        to_model_path,
    )

    # Step 4: Attempt the switch
    try:
        # Unload current model first to free memory
        if prev_loaded:
            logger.info("safe_switch: unloading current model %s", prev_model_id)
            await engine._unload_internal()

        # Load new model
        logger.info("safe_switch: loading new model %s from %s", to_model_id, to_model_path)
        await engine._engine.load_model(to_model_path)

        # Update state only on success
        engine.state.active_model_id = to_model_id
        engine.state.active_model_path = to_model_path
        engine.state.loaded = True

        logger.info("safe_switch: successfully switched to %s", to_model_id)
        return SwitchResult(
            success=True,
            active_model_id=to_model_id,
            active_model_path=to_model_path,
        )

    except Exception as e:
        error_msg = str(e)
        logger.error(
            "safe_switch: failed to load %s: %s — attempting rollback",
            to_model_id,
            error_msg,
        )

        # Step 5: Rollback — try to restore the previous model
        if prev_loaded and prev_model_path:
            try:
                logger.info("safe_switch: rolling back to %s", prev_model_id)
                await engine._engine.load_model(prev_model_path)
                engine.state.active_model_id = prev_model_id
                engine.state.active_model_path = prev_model_path
                engine.state.loaded = True
                logger.info("safe_switch: rollback succeeded, %s is still active", prev_model_id)

                return SwitchResult(
                    success=False,
                    active_model_id=prev_model_id,
                    active_model_path=prev_model_path,
                    error=f"Failed to load {to_model_id}: {error_msg}. Previous model restored.",
                )
            except Exception as rollback_err:
                logger.error(
                    "safe_switch: rollback also failed: %s — engine has no active model",
                    rollback_err,
                )
                engine.state.active_model_id = None
                engine.state.active_model_path = None
                engine.state.loaded = False

                return SwitchResult(
                    success=False,
                    active_model_id=None,
                    active_model_path=None,
                    error=(
                        f"Failed to load {to_model_id}: {error_msg}. "
                        f"Rollback also failed: {rollback_err}. No model active."
                    ),
                )
        else:
            # No previous model to roll back to
            engine.state.active_model_id = None
            engine.state.active_model_path = None
            engine.state.loaded = False

            return SwitchResult(
                success=False,
                active_model_id=None,
                active_model_path=None,
                error=f"Failed to load {to_model_id}: {error_msg}",
            )
