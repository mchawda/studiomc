# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""MLX LoRA/QLoRA trainer — GPU-accelerated fine-tuning on Apple Silicon.

Uses mlx-lm's built-in LoRA tuner for Metal-accelerated training. This
is the preferred training path on Apple Silicon because:
  - Native GPU acceleration via Metal (no CPU fallback)
  - Unified memory: full system RAM available for training
  - 2-4x faster than PyTorch MPS for LoRA fine-tuning
  - Built-in support for QLoRA (quantized base + LoRA adapters)

Falls back to the PyTorch PEFT trainer if MLX is unavailable.
"""

from __future__ import annotations

import asyncio
import json
import logging
import platform
import shutil
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from training.tokenizer_utils import TrainingSample, format_training_samples

logger = logging.getLogger("training.mlx_trainer")

_IS_APPLE_SILICON = platform.machine() == "arm64" and platform.system() == "Darwin"
_HAS_MLX = False
_HAS_MLX_LM = False

if _IS_APPLE_SILICON:
    try:
        import mlx.core as mx

        _HAS_MLX = True
    except ImportError:
        pass

    try:
        import mlx_lm
        from mlx_lm import lora as mlx_lora

        _HAS_MLX_LM = True
    except ImportError:
        pass

MLX_TRAINING_AVAILABLE = _HAS_MLX and _HAS_MLX_LM and _IS_APPLE_SILICON


@dataclass
class MLXTrainingResult:
    """Outcome of an MLX LoRA training run."""

    success: bool
    format: str  # "mlx_lora"
    adapter_dir: str
    num_samples: int
    num_steps: int
    final_loss: float | None = None
    error: str | None = None
    metrics: dict | None = None


def _find_mlx_model_path(base_model_id: str) -> Path | None:
    """Find an MLX-compatible model on disk.

    Searches:
      1. ~/.studiomc/models/<base_model_id>/
      2. All subdirs of ~/.studiomc/models/
    """
    from common.config import MODELS_DIR

    candidates: list[Path] = []

    exact = MODELS_DIR / base_model_id
    if exact.is_dir():
        candidates.append(exact)

    if MODELS_DIR.is_dir():
        for child in MODELS_DIR.iterdir():
            if child.is_dir() and child not in candidates:
                candidates.append(child)

    for path in candidates:
        config_file = path / "config.json"
        if not config_file.exists():
            continue
        try:
            with open(config_file) as f:
                cfg = json.load(f)
            if not cfg.get("architectures") and not cfg.get("model_type"):
                continue
            has_weights = any(path.glob("*.safetensors")) or any(
                path.glob("*.npz")
            )
            if has_weights:
                logger.info("Found MLX-compatible model at %s", path)
                return path
        except (json.JSONDecodeError, OSError):
            continue

    return None


def _samples_to_jsonl_chat(samples: list[TrainingSample]) -> str:
    """Convert training samples to JSONL chat format for mlx-lm tuner.

    mlx-lm expects JSONL where each line has a "messages" key containing
    a list of role/content dicts.
    """
    lines: list[str] = []
    for s in samples:
        if s.question and s.answer:
            messages = [
                {"role": "user", "content": s.question},
                {"role": "assistant", "content": s.answer},
            ]
        else:
            text = s.to_prompt(include_response=True)
            messages = [
                {"role": "user", "content": "Continue the following:"},
                {"role": "assistant", "content": text},
            ]
        lines.append(json.dumps({"messages": messages}))
    return "\n".join(lines)


async def train_mlx_lora(
    adapter_dir: Path,
    base_model_id: str,
    training_text: str,
    source_type: str,
    max_steps: int = 100,
    learning_rate: float = 1e-4,
    lora_rank: int = 8,
    lora_alpha: float = 16.0,
    lora_dropout: float = 0.0,
    batch_size: int = 1,
    lora_layers: int = 16,
    use_qlora: bool = False,
    progress_callback: Callable[[float, int], None] | None = None,
) -> MLXTrainingResult:
    """Run LoRA fine-tuning using mlx-lm on Apple Silicon GPU.

    This leverages Metal for GPU-accelerated training with the full
    system unified memory available.
    """
    if not MLX_TRAINING_AVAILABLE:
        missing = []
        if not _IS_APPLE_SILICON:
            missing.append("not Apple Silicon")
        if not _HAS_MLX:
            missing.append("mlx")
        if not _HAS_MLX_LM:
            missing.append("mlx-lm")
        return MLXTrainingResult(
            success=False,
            format="mlx_lora",
            adapter_dir=str(adapter_dir),
            num_samples=0,
            num_steps=0,
            error=f"MLX training unavailable: missing {', '.join(missing)}",
        )

    samples = format_training_samples(training_text)
    if not samples:
        return MLXTrainingResult(
            success=False,
            format="mlx_lora",
            adapter_dir=str(adapter_dir),
            num_samples=0,
            num_steps=0,
            error="No usable training samples parsed from input.",
        )

    model_path = _find_mlx_model_path(base_model_id)
    if model_path is None:
        return MLXTrainingResult(
            success=False,
            format="mlx_lora",
            adapter_dir=str(adapter_dir),
            num_samples=len(samples),
            num_steps=0,
            error=f"No MLX-compatible model found for '{base_model_id}'",
        )

    if progress_callback:
        progress_callback(5.0, 120)

    def _blocking_train() -> MLXTrainingResult:
        tmp_dir = None
        try:
            tmp_dir = tempfile.mkdtemp(prefix="studiomc_mlx_train_")
            tmp_path = Path(tmp_dir)

            train_file = tmp_path / "train.jsonl"
            train_file.write_text(
                _samples_to_jsonl_chat(samples), encoding="utf-8"
            )

            valid_samples = samples[: max(1, len(samples) // 5)]
            valid_file = tmp_path / "valid.jsonl"
            valid_file.write_text(
                _samples_to_jsonl_chat(valid_samples), encoding="utf-8"
            )

            adapter_dir.mkdir(parents=True, exist_ok=True)

            if progress_callback:
                progress_callback(10.0, 100)

            logger.info(
                "Starting MLX LoRA training: model=%s, samples=%d, steps=%d, rank=%d, qlora=%s",
                model_path,
                len(samples),
                max_steps,
                lora_rank,
                use_qlora,
            )

            lora_config = {
                "rank": lora_rank,
                "alpha": lora_alpha,
                "dropout": lora_dropout,
                "scale": lora_alpha / lora_rank,
            }

            train_args = {
                "model": str(model_path),
                "data": tmp_dir,
                "adapter_path": str(adapter_dir),
                "iters": max_steps,
                "batch_size": batch_size,
                "learning_rate": learning_rate,
                "lora_layers": lora_layers,
                "lora_parameters": lora_config,
                "train": True,
                "test": False,
            }

            if use_qlora:
                train_args["quantize"] = True

            start_time = time.time()
            step_losses: list[float] = []

            try:
                from mlx_lm.tuner.trainer import TrainingArgs, train as mlx_train
                from mlx_lm.tuner.utils import build_schedule

                model, tokenizer = mlx_lm.load(str(model_path))

                if use_qlora:
                    try:
                        from mlx_lm.tuner.utils import quantize_model
                        model = quantize_model(model)
                    except (ImportError, AttributeError):
                        logger.warning("QLoRA quantization not available, using standard LoRA")

                from mlx_lm.tuner.lora import apply_lora_layers
                model = apply_lora_layers(model, lora_layers, lora_config)

                from mlx_lm.tuner.datasets import load_dataset
                train_set = load_dataset(
                    "chat", data_path=tmp_dir, split="train", tokenizer=tokenizer
                )
                valid_set = load_dataset(
                    "chat", data_path=tmp_dir, split="valid", tokenizer=tokenizer
                )

                training_args = TrainingArgs(
                    batch_size=batch_size,
                    iters=max_steps,
                    learning_rate=learning_rate,
                    steps_per_report=max(1, max_steps // 20),
                    steps_per_eval=max(max_steps // 4, 10),
                    adapter_path=str(adapter_dir),
                    save_every=max_steps,
                )

                def _report_fn(info: dict) -> None:
                    step = info.get("iteration", 0)
                    loss = info.get("train_loss", 0.0)
                    step_losses.append(loss)

                    if progress_callback:
                        elapsed = time.time() - start_time
                        eta = int((elapsed / max(step, 1)) * (max_steps - step))
                        pct = 15.0 + (step / max_steps) * 80.0
                        progress_callback(pct, eta)

                mlx_train(
                    model=model,
                    tokenizer=tokenizer,
                    args=training_args,
                    train_dataset=train_set,
                    val_dataset=valid_set,
                    training_callback=_report_fn,
                )

            except (ImportError, AttributeError, TypeError) as api_err:
                logger.warning(
                    "mlx-lm tuner API not compatible (%s), falling back to CLI",
                    api_err,
                )
                import subprocess

                cmd = [
                    sys.executable if "sys" in dir() else "python3",
                    "-m",
                    "mlx_lm.lora",
                    "--model",
                    str(model_path),
                    "--data",
                    tmp_dir,
                    "--adapter-path",
                    str(adapter_dir),
                    "--iters",
                    str(max_steps),
                    "--batch-size",
                    str(batch_size),
                    "--learning-rate",
                    str(learning_rate),
                    "--lora-layers",
                    str(lora_layers),
                    "--train",
                ]

                import sys as _sys

                proc = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    timeout=3600,
                )

                if proc.returncode != 0:
                    raise RuntimeError(
                        f"mlx-lm lora training failed: {proc.stderr[-500:]}"
                    )

                for line in proc.stdout.split("\n"):
                    if "loss" in line.lower():
                        try:
                            parts = line.split()
                            for i, p in enumerate(parts):
                                if "loss" in p.lower() and i + 1 < len(parts):
                                    step_losses.append(float(parts[i + 1].strip(",")))
                        except (ValueError, IndexError):
                            pass

            adapter_config = {
                "studiomc_format": "mlx_lora",
                "base_model_id": base_model_id,
                "model_path": str(model_path),
                "source_type": source_type,
                "lora_rank": lora_rank,
                "lora_alpha": lora_alpha,
                "lora_dropout": lora_dropout,
                "lora_layers": lora_layers,
                "num_samples": len(samples),
                "num_steps": max_steps,
                "batch_size": batch_size,
                "learning_rate": learning_rate,
                "use_qlora": use_qlora,
                "final_loss": step_losses[-1] if step_losses else None,
                "device": "apple_silicon_metal",
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }

            config_path = adapter_dir / "adapter_config.json"
            existing = {}
            if config_path.exists():
                try:
                    with open(config_path) as f:
                        existing = json.load(f)
                except (json.JSONDecodeError, OSError):
                    pass
            existing.update(adapter_config)
            config_path.write_text(json.dumps(existing, indent=2), encoding="utf-8")

            samples_path = adapter_dir / "training_samples.jsonl"
            samples_path.write_text(
                _samples_to_jsonl_chat(samples), encoding="utf-8"
            )

            final_loss = step_losses[-1] if step_losses else None
            avg_loss = (
                sum(step_losses) / len(step_losses) if step_losses else None
            )

            logger.info(
                "MLX LoRA training complete: %d steps, final_loss=%.4f, saved to %s",
                max_steps,
                final_loss or 0.0,
                adapter_dir,
            )

            return MLXTrainingResult(
                success=True,
                format="mlx_lora",
                adapter_dir=str(adapter_dir),
                num_samples=len(samples),
                num_steps=max_steps,
                final_loss=final_loss,
                metrics={
                    "final_loss": final_loss,
                    "avg_loss": avg_loss,
                    "step_losses": step_losses[-10:],
                    "device": "apple_silicon_metal",
                    "lora_rank": lora_rank,
                    "lora_layers": lora_layers,
                    "use_qlora": use_qlora,
                },
            )

        except Exception as e:
            logger.exception("MLX LoRA training failed")
            return MLXTrainingResult(
                success=False,
                format="mlx_lora",
                adapter_dir=str(adapter_dir),
                num_samples=len(samples),
                num_steps=0,
                error=str(e),
            )

        finally:
            if tmp_dir:
                try:
                    shutil.rmtree(tmp_dir, ignore_errors=True)
                except Exception:
                    pass

    return await asyncio.to_thread(_blocking_train)
