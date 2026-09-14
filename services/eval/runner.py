# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""CLI entry for the grounded-answering eval harness.

Modes:
  offline  Score a recorded JSONL of model outputs (default, CI-safe).
  live     Lexical (or optional CLaRa-hash) retrieve + stub generator.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections.abc import Sequence
from datetime import datetime, timezone
from pathlib import Path

from eval.fixtures import (
    DEFAULT_CORPUS,
    DEFAULT_GOLD,
    DEFAULT_RECORDED,
    attach_retrieved,
    load_corpus,
    load_gold,
    load_predictions,
)
from eval.generator import generate_stub
from eval.retrieval import retrieve_clara_hash, retrieve_lexical
from eval.scorer import score_dataset
from eval.types import CorpusChunk, GoldItem, Prediction, RunMetadata, SuiteScore

# Bump when metric definitions change so stored scores are comparable.
HARNESS_VERSION = "eval-v0.2"

# Live mode has no real model: the stub generator pastes retrieved spans.
STUB_MODEL_VERSION = "stub-generator"
UNKNOWN_MODEL_VERSION = "unknown"


def _sha256_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def input_reference(paths: dict[str, Path]) -> dict[str, dict[str, str | None]]:
    """Path + sha256 for every input file so a run can be reproduced."""
    return {
        name: {"path": str(path), "sha256": _sha256_file(path)}
        for name, path in paths.items()
    }


def infer_model_version(predictions: Sequence[Prediction]) -> str:
    """Single model version declared by recorded rows, else ``unknown``.

    Mixed versions are joined with ``+`` so a suite scored across two
    checkpoints is visibly not a clean measurement.
    """
    versions = sorted({p.model_version for p in predictions if p.model_version})
    if not versions:
        return UNKNOWN_MODEL_VERSION
    return "+".join(versions)


def build_metadata(
    *,
    model_version: str,
    mode: str,
    top_k: int,
    inputs: dict[str, Path],
    retriever: str | None = None,
) -> RunMetadata:
    reference: dict[str, object] = dict(input_reference(inputs))
    if retriever is not None:
        reference["retriever"] = retriever
    return RunMetadata(
        model_version=model_version,
        timestamp=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        input_reference=reference,
        harness_version=HARNESS_VERSION,
        mode=mode,
        top_k=top_k,
    )

_COL = (
    ("id", 12),
    ("kind", 18),
    ("ground", 7),
    ("cit_p", 6),
    ("cit_r", 6),
    ("f1", 6),
    ("refuse", 6),
    ("hit@k", 6),
    ("hallu", 6),
)


def _fmt(value: float | None, width: int) -> str:
    if value is None:
        return "-".rjust(width)
    return f"{value:.3f}".rjust(width)


def format_table(suite: SuiteScore) -> str:
    """Render a fixed-width summary table (no extra dependencies)."""
    headers = [name.ljust(width) if name == "id" or name == "kind" else name.rjust(width) for name, width in _COL]
    lines = [" ".join(headers), "-" * (sum(w for _n, w in _COL) + len(_COL) - 1)]
    for item in suite.items:
        refuse = "ok" if item.refusal_correct else "MISS"
        row = [
            item.id.ljust(12),
            item.kind.ljust(18),
            _fmt(item.grounding, 7),
            _fmt(item.citation_precision, 6),
            _fmt(item.citation_recall, 6),
            _fmt(item.citation_f1, 6),
            refuse.rjust(6),
            _fmt(item.retrieval_hit_at_k, 6),
            _fmt(item.citation_hallucination_rate, 6),
        ]
        lines.append(" ".join(row))
    lines.append("-" * (sum(w for _n, w in _COL) + len(_COL) - 1))
    refuse_macro = f"{suite.refusal_accuracy:.3f}"
    lines.append(
        " ".join(
            [
                "MACRO".ljust(12),
                f"n={suite.n}".ljust(18),
                _fmt(suite.grounding, 7),
                _fmt(suite.citation_precision, 6),
                _fmt(suite.citation_recall, 6),
                _fmt(suite.citation_f1, 6),
                refuse_macro.rjust(6),
                _fmt(suite.retrieval_hit_at_k, 6),
                _fmt(suite.citation_hallucination_rate, 6),
            ]
        )
    )
    lines.append(
        f"refusal_unanswerable={suite.refusal_accuracy_unanswerable:.3f}  "
        f"retrieval_recall@k={suite.retrieval_recall_at_k if suite.retrieval_recall_at_k is not None else '-'}"
    )
    if suite.metadata is not None:
        meta = suite.metadata
        lines.append(
            f"model={meta.model_version}  harness={meta.harness_version}  "
            f"mode={meta.mode}  at={meta.timestamp}"
        )
        for name, ref in sorted(meta.input_reference.items()):
            if isinstance(ref, dict) and "sha256" in ref:
                digest = ref.get("sha256") or "-"
                lines.append(f"input.{name}={ref.get('path')} sha256={str(digest)[:12]}")
    return "\n".join(lines)


def run_offline(
    gold: Sequence[GoldItem],
    predictions: Sequence[Prediction],
    corpus: Sequence[CorpusChunk],
    k: int,
    *,
    metadata: RunMetadata | None = None,
) -> SuiteScore:
    attached = [attach_retrieved(p, list(corpus)) for p in predictions]
    suite = score_dataset(gold, attached, k=k, corpus=corpus)
    suite.metadata = metadata
    return suite


def run_live(
    gold: Sequence[GoldItem],
    corpus: Sequence[CorpusChunk],
    k: int,
    retriever: str,
    *,
    metadata: RunMetadata | None = None,
) -> SuiteScore:
    predictions: list[Prediction] = []
    for item in gold:
        if retriever == "clara":
            retrieved = retrieve_clara_hash(item.question, corpus, top_k=k)
            if retrieved is None:
                retrieved = retrieve_lexical(item.question, corpus, top_k=k)
        else:
            retrieved = retrieve_lexical(item.question, corpus, top_k=k)
        predictions.append(
            generate_stub(item.id, item.question, retrieved, index_chunks=corpus)
        )
    suite = score_dataset(gold, predictions, k=k, corpus=corpus)
    suite.metadata = metadata
    return suite


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m eval",
        description="Score grounded-answering outputs (citation, grounding, refusal).",
    )
    parser.add_argument(
        "--mode",
        choices=("offline", "live"),
        default="offline",
        help="offline scores recorded JSONL; live uses lexical retrieve + stub generator",
    )
    parser.add_argument("--gold", type=Path, default=DEFAULT_GOLD)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--predictions", type=Path, default=DEFAULT_RECORDED)
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument(
        "--retriever",
        choices=("lexical", "clara"),
        default="lexical",
        help="live mode only. clara uses the Core TF-IDF hash encoder, never torch",
    )
    parser.add_argument("--json", action="store_true", help="print SuiteScore JSON instead of a table")
    parser.add_argument(
        "--json-out",
        type=Path,
        default=None,
        help="also write the SuiteScore JSON (with run metadata) to this file",
    )
    parser.add_argument(
        "--model-version",
        type=str,
        default=None,
        help="model that produced the predictions; defaults to the recorded rows' model_version",
    )
    parser.add_argument("--fail-under-grounding", type=float, default=0.0)
    parser.add_argument("--fail-under-refusal", type=float, default=0.0)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    gold = load_gold(args.gold)
    corpus = load_corpus(args.corpus)

    if args.mode == "live":
        metadata = build_metadata(
            model_version=args.model_version or STUB_MODEL_VERSION,
            mode="live",
            top_k=args.top_k,
            inputs={"gold": args.gold, "corpus": args.corpus},
            retriever=args.retriever,
        )
        suite = run_live(
            gold, corpus, k=args.top_k, retriever=args.retriever, metadata=metadata
        )
    else:
        predictions = load_predictions(args.predictions)
        metadata = build_metadata(
            model_version=args.model_version or infer_model_version(predictions),
            mode="offline",
            top_k=args.top_k,
            inputs={
                "gold": args.gold,
                "corpus": args.corpus,
                "predictions": args.predictions,
            },
        )
        suite = run_offline(gold, predictions, corpus, k=args.top_k, metadata=metadata)

    payload = suite.to_dict()
    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    if args.json:
        sys.stdout.write(json.dumps(payload, indent=2) + "\n")
    else:
        sys.stdout.write(format_table(suite) + "\n")

    failed = False
    if suite.grounding < args.fail_under_grounding:
        sys.stderr.write(
            f"grounding {suite.grounding:.3f} < --fail-under-grounding {args.fail_under_grounding}\n"
        )
        failed = True
    if suite.refusal_accuracy < args.fail_under_refusal:
        sys.stderr.write(
            f"refusal_accuracy {suite.refusal_accuracy:.3f} < --fail-under-refusal {args.fail_under_refusal}\n"
        )
        failed = True
    return 1 if failed else 0
