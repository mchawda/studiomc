# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc 4B specialized-model recipe (constants only, no ML imports).

Base model choice
-----------------
``Qwen/Qwen3-4B-Instruct-2507`` (4.0B, Apache-2.0).

Why this one, not Phi-4-mini or Gemma 3 4B:

* Strongest current ~4B instruct checkpoint (July 2025 refresh) for
  tool use, multilingual follow, and long context (256K native).
* Non-thinking instruct variant: no ``<think>`` tokens that would fight
  the citation / refuse / LRE-tool SFT mix.
* Unsloth ``FastLanguageModel`` supports it first-class, including the
  optional ``qat_scheme="int8-int4"`` path for later phone quants.
* Q4_K_M GGUF is 2.50 GB, which sits in Autopilot's 3-6 GB desktop band.
* Phi-4-mini (``microsoft/Phi-4-mini-instruct``) is coding-strong but
  weaker on tool-calling and multilingual grounded QA.
* Gemma 3 4B (``google/gemma-3-4b-it``) is gated and less mature on the
  Unsloth QAT path. Revisit if we need Gemma-specific mobile runtimes.

The catalog GGUF (until a trained Studiomc export is published) is the
bartowski Q4_K_M of the same instruct checkpoint. After ``train`` +
``export``, replace ``CATALOG_GGUF_REPO`` / ``CATALOG_GGUF_FILE`` with
the specialized artifact.

QAT / mobile follow-up
----------------------
Pass ``--qat`` to enable Unsloth QAT (int8 activations, int4 weights).
That is the scheme we want before ExecuTorch (.pte) or CoreML
(.mlpackage) conversion. Those converters are **not** part of this
pipeline: desktop ships GGUF through llama-server first.
"""

from __future__ import annotations

# ── Identity ──────────────────────────────────────────────────────────

SPECIALIZED_MODEL_ID = "studiomc-4b"
SPECIALIZED_MODEL_NAME = "Studiomc 4B"
SPECIALIZED_ARCH = "qwen3"
SPECIALIZED_PARAMS_BILLION = 4.0
SPECIALIZED_CONTEXT_MAX = 262_144
SPECIALIZED_QUANT = "Q4_K_M"
SPECIALIZED_DISK_BYTES = 2_497_280_736  # bartowski Q4_K_M, 2.50 GB

# Autopilot: prefer this class when RAM/VRAM can hold a ~3-6 GB model.
DESKTOP_DEFAULT_MIN_RAM_BYTES = 8 * 1024**3
DESKTOP_BAND_PARAMS = (3.0, 6.0)

# ── HuggingFace ids (must exist) ──────────────────────────────────────

BASE_MODEL_ID = "Qwen/Qwen3-4B-Instruct-2507"
# Unsloth mirror: same weights, faster 4-bit load. Trainer tries this first.
UNSLOTH_BASE_MODEL_ID = "unsloth/Qwen3-4B-Instruct-2507"

CATALOG_GGUF_REPO = "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF"
CATALOG_GGUF_FILE = "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
CATALOG_GGUF_URL = (
    f"https://huggingface.co/{CATALOG_GGUF_REPO}/resolve/main/{CATALOG_GGUF_FILE}"
)

# ── LoRA ──────────────────────────────────────────────────────────────

LORA_RANK = 16
LORA_ALPHA = 32
LORA_DROPOUT = 0.0  # Unsloth fast path wants 0
LORA_TARGET_MODULES = [
    "q_proj",
    "k_proj",
    "v_proj",
    "o_proj",
    "gate_proj",
    "up_proj",
    "down_proj",
]

# ── Train hyperparams ─────────────────────────────────────────────────

MAX_SEQ_LENGTH = 4096
PER_DEVICE_BATCH_SIZE = 2
GRAD_ACCUM_STEPS = 4
LEARNING_RATE = 2e-4
WARMUP_STEPS = 5
DEFAULT_MAX_STEPS = 80
DEFAULT_EPOCHS = 1
WEIGHT_DECAY = 0.01
SEED = 3407

# Optional Unsloth QAT scheme. "int8-int4" is the phone-deployment target.
# Desktop GGUF export does not require it. Enable with --qat.
QAT_SCHEME = "int8-int4"
GGUF_QUANT = "q4_k_m"

# ── System prompt (SFT + inference) ───────────────────────────────────

SYSTEM_PROMPT = """You are Studiomc, a local research assistant.

Rules:
1. Grounded answers use ONLY the evidence in the prompt. Cite each claim
   inline as [Source N] matching the numbered sources.
2. If the evidence does not contain the answer, refuse. Say you cannot
   answer from the given sources. Do not invent citations or facts.
3. Investigate / tool use: emit LRE tool steps as JSON objects
   {"tool": "<name>", "params": {...}}. Allowed tools: search, grep,
   open, summarize, table_extract, cite, inference.
4. When you must call a tool during a turn, wrap one object in
   <tool_call> ... </tool_call>. Do not call tools you do not need.
5. Never claim you browsed the live web. You only see retrieved chunks
   and LRE tool results."""


def is_studiomc_specialized(model_id: str | None, name: str | None = None) -> bool:
    """True for Studiomc-branded catalog entries (id or display name)."""
    mid = (model_id or "").lower()
    nm = (name or "").lower()
    return mid.startswith("studiomc-") or nm.startswith("studiomc")


def is_desktop_default_candidate(
    model_id: str | None,
    name: str | None = None,
    params_billion: float | None = None,
) -> bool:
    """True for a Studiomc 3-6B model Autopilot may pin as desktop default."""
    if not is_studiomc_specialized(model_id, name):
        return False
    params = params_billion or 0.0
    lo, hi = DESKTOP_BAND_PARAMS
    return lo <= params <= hi
