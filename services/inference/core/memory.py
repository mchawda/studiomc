"""Memory management utilities for out-of-core inference.

Provides aggressive memory cleanup between layer computations to ensure
that only one layer's worth of weights is resident in memory at a time.
"""

from __future__ import annotations

import ctypes
import gc
import logging

import torch

logger = logging.getLogger("inference.core.memory")


def clean_memory() -> None:
    """Aggressively free memory after layer computation.

    Performs three levels of cleanup:
    1. Python garbage collection (frees unreferenced Python objects)
    2. CUDA/MPS cache clearing (returns GPU memory to the allocator)
    3. libc malloc_trim on Linux (returns freed heap to the OS)
    """
    gc.collect()

    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.synchronize()

    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        # MPS doesn't have empty_cache yet, but synchronize helps
        try:
            torch.mps.synchronize()  # type: ignore[attr-defined]
        except (AttributeError, RuntimeError):
            pass

    # On Linux, return freed heap memory to the OS
    try:
        libc = ctypes.CDLL("libc.so.6")
        libc.malloc_trim(0)
    except (OSError, AttributeError):
        pass
