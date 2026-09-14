# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc 4B specialized-model pipeline (torch-free public surface).

Import ``training.studiomc_model.unsloth_trainer`` only from a Pro-pack
process when you actually train. This package init never imports Unsloth
or torch.
"""

from training.studiomc_model.data import (
    case_to_messages,
    case_to_sft_row,
    cases_from_eval_harness,
    format_assistant,
    format_user_prompt,
    generate_sft_rows,
    load_cases,
    load_seed_cases,
)
from training.studiomc_model.recipe import (
    BASE_MODEL_ID,
    CATALOG_GGUF_FILE,
    CATALOG_GGUF_REPO,
    SPECIALIZED_MODEL_ID,
    SPECIALIZED_MODEL_NAME,
    is_desktop_default_candidate,
    is_studiomc_specialized,
)
from training.studiomc_model.schema import EvalCase, normalize_eval_record

__all__ = [
    "BASE_MODEL_ID",
    "CATALOG_GGUF_FILE",
    "CATALOG_GGUF_REPO",
    "SPECIALIZED_MODEL_ID",
    "SPECIALIZED_MODEL_NAME",
    "EvalCase",
    "case_to_messages",
    "case_to_sft_row",
    "cases_from_eval_harness",
    "format_assistant",
    "format_user_prompt",
    "generate_sft_rows",
    "is_desktop_default_candidate",
    "is_studiomc_specialized",
    "load_cases",
    "load_seed_cases",
    "normalize_eval_record",
]
