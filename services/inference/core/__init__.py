# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""SpliceLLM inference core — out-of-core model inference engine.

This package implements the SpliceLLM engine that can run models of any
size by streaming layers from disk through memory one at a time.

Modules:
    switch_types   — Pure dataclasses (torch-free, safe for Core code)
    memory_guard   — OOM prevention and memory monitoring (torch-free)
    adapter_loader — PEFT LoRA adapter loading (lazy: only needs torch on use)
    memory         — Memory cleanup helpers (Pro pack: imports torch)
    splitter       — Splits HuggingFace models into per-layer safetensors (Pro)
    loader         — Loads individual layers from disk to device (Pro)
    out_of_core    — Main SpliceLLM inference engine (Pro)
    speculative    — Speculative (draft-then-verify) decoding (Pro)

This package intentionally has **no eager re-exports**. Importing
``inference.core`` is free; importing a Pro submodule (``loader``,
``out_of_core``, ``memory``, ``splitter``, ``speculative``) requires the
Pro pack. See ``SPLIT_BUNDLE.md``.
"""
