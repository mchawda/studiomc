"""Layer loader — loads individual layers from split safetensors files.

Provides efficient loading of per-layer weight files with optional
background prefetching for pipelining disk I/O with computation.
"""

from __future__ import annotations

import logging
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path

import torch
from safetensors.torch import load_file

logger = logging.getLogger("inference.core.loader")


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
