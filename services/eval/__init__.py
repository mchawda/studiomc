# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Grounded-answering eval harness for Studiomc.

This package is the offline/CI half of the specialized-model moat:
citation precision, claim grounding, and correct "I don't know"
refusals. The scorer never imports torch or CLaRa.

Run:
    cd services && PYTHONPATH=. python -m eval
    cd services && PYTHONPATH=. python -m eval --mode live
    cd services && PYTHONPATH=. python -m pytest tests/test_eval_harness.py
"""

from eval.metrics import (
    grounding_score,
    is_refusal_text,
    precision_recall,
)
from eval.scorer import aggregate, score_dataset, score_prediction
from eval.types import GoldItem, ItemScore, Prediction, SourceRef, SuiteScore

__all__ = [
    "GoldItem",
    "ItemScore",
    "Prediction",
    "SourceRef",
    "SuiteScore",
    "aggregate",
    "grounding_score",
    "is_refusal_text",
    "precision_recall",
    "score_dataset",
    "score_prediction",
]
