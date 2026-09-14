# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Unsloth FastLanguageModel train + GGUF export (import-guarded).

This module is Pro-pack only. Core must never import it at service
startup. The CLI loads it after ``common.pro_pack.require("training")``
when a real train/export is requested.

Unsloth, torch, and transformers are optional. Missing deps raise
:class:`UnslothUnavailableError` so unit tests can run on CPU-only CI.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from training.studiomc_model.recipe import (
    BASE_MODEL_ID,
    DEFAULT_MAX_STEPS,
    GGUF_QUANT,
    GRAD_ACCUM_STEPS,
    LEARNING_RATE,
    LORA_ALPHA,
    LORA_DROPOUT,
    LORA_RANK,
    LORA_TARGET_MODULES,
    MAX_SEQ_LENGTH,
    PER_DEVICE_BATCH_SIZE,
    QAT_SCHEME,
    SEED,
    SPECIALIZED_MODEL_ID,
    UNSLOTH_BASE_MODEL_ID,
    WARMUP_STEPS,
    WEIGHT_DECAY,
)

logger = logging.getLogger("training.studiomc_model")


class UnslothUnavailableError(RuntimeError):
    """Unsloth / torch is not installed. Expected on Core-only machines."""


@dataclass
class TrainJob:
    """Resolved train/export paths and knobs (no live model objects)."""

    data_path: Path
    output_dir: Path
    base_model: str = UNSLOTH_BASE_MODEL_ID
    max_steps: int = DEFAULT_MAX_STEPS
    max_seq_length: int = MAX_SEQ_LENGTH
    learning_rate: float = LEARNING_RATE
    lora_rank: int = LORA_RANK
    qat: bool = False
    gguf_quant: str = GGUF_QUANT


@dataclass
class TrainResult:
    success: bool
    adapter_dir: str
    gguf_path: str | None = None
    num_rows: int = 0
    num_steps: int = 0
    qat_scheme: str | None = None
    error: str | None = None


def unsloth_available() -> bool:
    """True only if Unsloth imported cleanly. Never raises."""
    try:
        import unsloth  # noqa: F401
    except ImportError:
        return False
    return True


def require_unsloth() -> None:
    """Raise :class:`UnslothUnavailableError` with an install hint."""
    if unsloth_available():
        return
    raise UnslothUnavailableError(
        "Unsloth is not installed. Use the Pro pack Python and run: "
        "pip install unsloth. Then: python -m training.studiomc_model train "
        "--data <sft.jsonl> --output <dir>"
    )


def _count_jsonl_rows(path: Path) -> int:
    n = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            n += 1
    return n


def _write_adapter_meta(adapter_dir: Path, job: TrainJob, num_rows: int) -> None:
    meta = {
        "studiomc_format": "unsloth_lora",
        "specialized_model_id": SPECIALIZED_MODEL_ID,
        "base_model_id": job.base_model,
        "fallback_base_model_id": BASE_MODEL_ID,
        "lora_rank": job.lora_rank,
        "lora_alpha": LORA_ALPHA,
        "lora_dropout": LORA_DROPOUT,
        "target_modules": LORA_TARGET_MODULES,
        "qat_scheme": QAT_SCHEME if job.qat else None,
        "max_seq_length": job.max_seq_length,
        "max_steps": job.max_steps,
        "num_rows": num_rows,
        "data_path": str(job.data_path),
    }
    (adapter_dir / "studiomc_train.json").write_text(
        json.dumps(meta, indent=2), encoding="utf-8"
    )


def train(job: TrainJob) -> TrainResult:
    """Run Unsloth LoRA (optional QAT) and save the adapter.

    Does not touch a GPU unless Unsloth is installed and this function
    is actually called. Tests should call :func:`unsloth_available` and
    expect :class:`UnslothUnavailableError` instead of invoking train.
    """
    require_unsloth()
    if not job.data_path.is_file():
        return TrainResult(
            success=False,
            adapter_dir=str(job.output_dir),
            error=f"SFT JSONL not found: {job.data_path}",
        )

    num_rows = _count_jsonl_rows(job.data_path)
    job.output_dir.mkdir(parents=True, exist_ok=True)

    try:
        from datasets import load_dataset
        from trl import SFTConfig, SFTTrainer
        from unsloth import FastLanguageModel
    except ImportError as exc:
        raise UnslothUnavailableError(
            f"Unsloth stack incomplete ({exc}). Install unsloth, datasets, trl."
        ) from exc

    load_name = job.base_model
    try:
        model, tokenizer = FastLanguageModel.from_pretrained(
            model_name=load_name,
            max_seq_length=job.max_seq_length,
            load_in_4bit=True,
        )
    except Exception:
        if load_name != BASE_MODEL_ID:
            logger.warning("Unsloth id %s failed, falling back to %s", load_name, BASE_MODEL_ID)
            load_name = BASE_MODEL_ID
            model, tokenizer = FastLanguageModel.from_pretrained(
                model_name=load_name,
                max_seq_length=job.max_seq_length,
                load_in_4bit=True,
            )
        else:
            raise

    peft_kwargs: dict[str, Any] = {
        "r": job.lora_rank,
        "target_modules": LORA_TARGET_MODULES,
        "lora_alpha": LORA_ALPHA,
        "lora_dropout": LORA_DROPOUT,
        "bias": "none",
        "use_gradient_checkpointing": "unsloth",
        "random_state": SEED,
    }
    # QAT: fake-quant during train so weights survive int4 GGUF / later
    # ExecuTorch int8-int4 phone deployment. Optional; desktop GGUF works
    # without it.
    if job.qat:
        peft_kwargs["qat_scheme"] = QAT_SCHEME

    model = FastLanguageModel.get_peft_model(model, **peft_kwargs)

    dataset = load_dataset("json", data_files=str(job.data_path), split="train")

    def _to_text(batch: dict[str, Any]) -> dict[str, list[str]]:
        texts: list[str] = []
        for messages in batch["messages"]:
            texts.append(
                tokenizer.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=False
                )
            )
        return {"text": texts}

    dataset = dataset.map(_to_text, batched=True, remove_columns=dataset.column_names)

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=dataset,
        args=SFTConfig(
            output_dir=str(job.output_dir / "runs"),
            per_device_train_batch_size=PER_DEVICE_BATCH_SIZE,
            gradient_accumulation_steps=GRAD_ACCUM_STEPS,
            learning_rate=job.learning_rate,
            warmup_steps=WARMUP_STEPS,
            max_steps=job.max_steps,
            weight_decay=WEIGHT_DECAY,
            logging_steps=5,
            seed=SEED,
            dataset_text_field="text",
            max_seq_length=job.max_seq_length,
        ),
    )
    trainer.train()

    adapter_dir = job.output_dir / "adapter"
    adapter_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(str(adapter_dir))
    tokenizer.save_pretrained(str(adapter_dir))
    _write_adapter_meta(adapter_dir, job, num_rows)

    return TrainResult(
        success=True,
        adapter_dir=str(adapter_dir),
        num_rows=num_rows,
        num_steps=job.max_steps,
        qat_scheme=QAT_SCHEME if job.qat else None,
    )


def export_gguf(adapter_dir: Path, gguf_path: Path, *, quant: str = GGUF_QUANT) -> Path:
    """Merge LoRA and write a GGUF via Unsloth's converter.

    Follow-up (not implemented here): convert the merged 16-bit dir with
    ExecuTorch or coremltools. Desktop Autopilot consumes this GGUF.
    """
    require_unsloth()
    from unsloth import FastLanguageModel

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=str(adapter_dir),
        max_seq_length=MAX_SEQ_LENGTH,
        load_in_4bit=True,
    )
    gguf_path.parent.mkdir(parents=True, exist_ok=True)
    # Unsloth writes <dir>/<name>.gguf. We pass the parent and then move.
    tmp_dir = gguf_path.parent / f".{gguf_path.stem}-gguf-tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    FastLanguageModel.for_inference(model)
    model.save_pretrained_gguf(str(tmp_dir), tokenizer, quantization_method=quant)
    produced = sorted(tmp_dir.glob("*.gguf"))
    if not produced:
        raise RuntimeError(f"Unsloth GGUF export produced no file in {tmp_dir}")
    produced[-1].replace(gguf_path)
    return gguf_path
