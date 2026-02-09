"""Studiomc inference core — out-of-core model inference engine.

This package implements Studiomc's own out-of-core inference engine that
can run models of any size by streaming layers from disk through memory
one at a time.

Modules:
    memory      — Memory management utilities (aggressive cleanup)
    splitter    — Splits HuggingFace models into per-layer safetensors
    loader      — Loads individual layers from disk to device
    out_of_core — Main inference engine orchestrating layer-by-layer forward passes
"""

from inference.core.memory import clean_memory
from inference.core.splitter import split_model
from inference.core.loader import LayerLoader
from inference.core.out_of_core import OutOfCoreEngine

__all__ = [
    "clean_memory",
    "split_model",
    "LayerLoader",
    "OutOfCoreEngine",
]
