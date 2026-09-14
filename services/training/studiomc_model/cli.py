# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""CLI for the Studiomc 4B pipeline. Torch-free unless train/export is invoked."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def _services_dir() -> Path:
    return Path(__file__).resolve().parents[2]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m training.studiomc_model",
        description="Studiomc 4B SFT data + Unsloth LoRA/QAT + GGUF export",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate", help="Write chat-format SFT JSONL from fixtures and/or eval")
    gen.add_argument("--out", type=Path, required=True, help="Destination JSONL")
    gen.add_argument(
        "--from-eval",
        type=Path,
        action="append",
        default=[],
        help="Eval-harness JSONL (repeatable). Native fixtures are always included.",
    )
    gen.add_argument(
        "--fixtures-only",
        action="store_true",
        help="Ignore --from-eval (used in tests)",
    )

    dry = sub.add_parser("dry-run", help="Format data and print counts. No GPU, no Unsloth.")
    dry.add_argument("--data", type=Path, default=None, help="Existing SFT JSONL to inspect")
    dry.add_argument(
        "--from-eval",
        type=Path,
        action="append",
        default=[],
        help="Optional eval JSONL to merge when --data is omitted",
    )

    train = sub.add_parser("train", help="Unsloth LoRA fine-tune (requires Pro pack + Unsloth)")
    train.add_argument("--data", type=Path, required=True)
    train.add_argument("--output", type=Path, required=True)
    train.add_argument("--max-steps", type=int, default=None)
    train.add_argument("--qat", action="store_true", help="Enable Unsloth qat_scheme=int8-int4")
    train.add_argument("--base-model", type=str, default=None)
    train.add_argument("--export-gguf", type=Path, default=None, help="Also write this GGUF path")

    export = sub.add_parser("export", help="Merge adapter and write GGUF (requires Unsloth)")
    export.add_argument("--adapter-dir", type=Path, required=True)
    export.add_argument("--gguf", type=Path, required=True)
    export.add_argument("--quant", type=str, default=None)

    return parser


def _cmd_generate(args: argparse.Namespace) -> int:
    from training.studiomc_model.data import generate_sft_rows, write_sft_jsonl

    extra = [] if args.fixtures_only else list(args.from_eval)
    rows = generate_sft_rows(
        extra_paths=extra,
        include_eval_harness=not args.fixtures_only,
    )
    write_sft_jsonl(rows, args.out)
    tasks: dict[str, int] = {}
    for row in rows:
        tasks[row["task"]] = tasks.get(row["task"], 0) + 1
    print(json.dumps({"out": str(args.out), "rows": len(rows), "tasks": tasks}, indent=2))
    return 0


def _cmd_dry_run(args: argparse.Namespace) -> int:
    from training.studiomc_model.data import generate_sft_rows, load_cases
    from training.studiomc_model.recipe import BASE_MODEL_ID, SPECIALIZED_MODEL_ID
    from training.studiomc_model.unsloth_trainer import unsloth_available

    if args.data is not None:
        n = sum(1 for line in args.data.read_text(encoding="utf-8").splitlines() if line.strip())
        print(json.dumps({
            "mode": "inspect",
            "data": str(args.data),
            "rows": n,
            "base_model": BASE_MODEL_ID,
            "catalog_id": SPECIALIZED_MODEL_ID,
            "unsloth": unsloth_available(),
        }, indent=2))
        return 0

    rows = generate_sft_rows(extra_paths=list(args.from_eval), include_eval_harness=True)
    tasks: dict[str, int] = {}
    for row in rows:
        tasks[row["task"]] = tasks.get(row["task"], 0) + 1
    sample = rows[0]["messages"][-1]["content"][:180] if rows else ""
    print(json.dumps({
        "mode": "format",
        "rows": len(rows),
        "tasks": tasks,
        "base_model": BASE_MODEL_ID,
        "catalog_id": SPECIALIZED_MODEL_ID,
        "unsloth": unsloth_available(),
        "sample_assistant_prefix": sample,
    }, indent=2))
    # Touch load_cases so a bad fixture fails here, not at train time.
    if args.from_eval:
        for path in args.from_eval:
            load_cases(path)
    return 0


def _cmd_train(args: argparse.Namespace) -> int:
    from training.studiomc_model.recipe import (
        DEFAULT_MAX_STEPS,
        GGUF_QUANT,
        UNSLOTH_BASE_MODEL_ID,
    )
    from training.studiomc_model.unsloth_trainer import (
        TrainJob,
        UnslothUnavailableError,
        export_gguf,
        train,
    )

    job = TrainJob(
        data_path=args.data,
        output_dir=args.output,
        base_model=args.base_model or UNSLOTH_BASE_MODEL_ID,
        max_steps=args.max_steps or DEFAULT_MAX_STEPS,
        qat=bool(args.qat),
        gguf_quant=GGUF_QUANT,
    )
    try:
        result = train(job)
    except UnslothUnavailableError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if not result.success:
        print(result.error or "train failed", file=sys.stderr)
        return 1
    gguf = None
    if args.export_gguf is not None:
        gguf = str(export_gguf(Path(result.adapter_dir), args.export_gguf))
        result.gguf_path = gguf
    print(json.dumps({
        "success": result.success,
        "adapter_dir": result.adapter_dir,
        "gguf_path": result.gguf_path,
        "num_rows": result.num_rows,
        "num_steps": result.num_steps,
        "qat_scheme": result.qat_scheme,
    }, indent=2))
    return 0


def _cmd_export(args: argparse.Namespace) -> int:
    from training.studiomc_model.recipe import GGUF_QUANT
    from training.studiomc_model.unsloth_trainer import UnslothUnavailableError, export_gguf

    try:
        path = export_gguf(args.adapter_dir, args.gguf, quant=args.quant or GGUF_QUANT)
    except UnslothUnavailableError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    print(json.dumps({"gguf": str(path)}, indent=2))
    return 0


def main(argv: list[str] | None = None) -> int:
    # Make `python -m training.studiomc_model` work from repo root or services/.
    services = str(_services_dir())
    if services not in sys.path:
        sys.path.insert(0, services)

    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "generate":
        return _cmd_generate(args)
    if args.cmd == "dry-run":
        return _cmd_dry_run(args)
    if args.cmd == "train":
        return _cmd_train(args)
    if args.cmd == "export":
        return _cmd_export(args)
    parser.error(f"unknown command {args.cmd}")
    return 2
