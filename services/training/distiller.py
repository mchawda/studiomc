# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Knowledge Distillation — teacher-student model compression.

Phase 4: Implements teacher-student distillation where a larger (teacher)
model transfers knowledge to a smaller (student) model.

The student learns from both:
  - Hard labels (ground truth)
  - Soft labels (teacher probability distributions)

Loss = alpha * KL_divergence(student, teacher) + (1 - alpha) * cross_entropy(student, labels)

Supports:
  - Local teacher (existing downloaded model)
  - Cloud teacher (frontier API — requires explicit consent)
  - Progress tracking with callbacks
  - Evaluation: compare student vs teacher on test data
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

import numpy as np

from common.config import ADAPTERS_DIR, MODELS_DIR
from common.database import Database
from training.tokenizer_utils import count_tokens, format_training_samples, TrainingSample

logger = logging.getLogger("training.distiller")

# ── Optional dependency detection ────────────────────────────────

_HAS_TORCH = False
_HAS_PEFT = False
_HAS_TRANSFORMERS = False

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F

    _HAS_TORCH = True
except ImportError:
    torch = None  # type: ignore[assignment]

try:
    from transformers import AutoModelForCausalLM, AutoTokenizer, AutoConfig

    _HAS_TRANSFORMERS = True
except ImportError:
    pass

try:
    from peft import LoraConfig, get_peft_model, TaskType

    _HAS_PEFT = True
except ImportError:
    pass


# ── Distillation result ──────────────────────────────────────────


@dataclass
class DistillResult:
    """Outcome of a knowledge distillation run."""

    success: bool
    adapter_dir: str = ""
    num_samples: int = 0
    epochs_completed: int = 0
    final_loss: float | None = None
    teacher_metrics: dict[str, Any] = field(default_factory=dict)
    student_metrics: dict[str, Any] = field(default_factory=dict)
    error: str | None = None
    metrics: dict[str, Any] = field(default_factory=dict)


# ── Device helpers (reuse pattern from lora_trainer) ─────────────


def _select_device() -> str:
    if not _HAS_TORCH:
        return "cpu"
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _get_dtype(device: str) -> "torch.dtype":
    if device == "cuda":
        if torch.cuda.is_bf16_supported():
            return torch.bfloat16
        return torch.float16
    return torch.float32


def _find_model_path(model_id: str) -> Path | None:
    """Search for a transformers-compatible model on disk."""
    candidates: list[Path] = []

    user_model_dir = MODELS_DIR / model_id
    if user_model_dir.is_dir():
        candidates.append(user_model_dir)

    if MODELS_DIR.is_dir():
        for child in MODELS_DIR.iterdir():
            if child.is_dir() and child not in candidates:
                candidates.append(child)

    project_root = Path(__file__).resolve().parent.parent.parent
    project_models = project_root / "models"
    if project_models.is_dir():
        for child in sorted(project_models.iterdir()):
            if child.is_dir() and child not in candidates:
                candidates.append(child)

    for path in candidates:
        config_file = path / "config.json"
        if not config_file.exists():
            continue
        try:
            with open(config_file) as f:
                cfg = json.load(f)
            if cfg.get("architectures") or cfg.get("model_type"):
                has_weights = (
                    any(path.glob("*.safetensors"))
                    or any(path.glob("*.bin"))
                    or (path / "model.safetensors.index.json").exists()
                )
                if has_weights:
                    return path
        except (json.JSONDecodeError, OSError):
            continue

    return None


# ── Target module inference ──────────────────────────────────────

_TARGET_MODULES_MAP: dict[str, list[str]] = {
    "llama": ["q_proj", "k_proj", "v_proj", "o_proj"],
    "mistral": ["q_proj", "k_proj", "v_proj", "o_proj"],
    "gpt2": ["c_attn", "c_proj"],
    "gpt_neo": ["q_proj", "k_proj", "v_proj"],
    "phi": ["q_proj", "k_proj", "v_proj", "dense"],
    "phi3": ["qkv_proj", "o_proj"],
    "gemma": ["q_proj", "k_proj", "v_proj", "o_proj"],
    "qwen2": ["q_proj", "k_proj", "v_proj", "o_proj"],
}

_DEFAULT_TARGET_MODULES = ["q_proj", "k_proj", "v_proj", "o_proj"]


def _infer_target_modules(model_type: str | None) -> list[str]:
    if model_type and model_type in _TARGET_MODULES_MAP:
        return _TARGET_MODULES_MAP[model_type]
    return _DEFAULT_TARGET_MODULES


# ── Core distiller class ─────────────────────────────────────────


class KnowledgeDistiller:
    """Implements teacher-student knowledge distillation.

    The teacher generates soft labels (probability distributions) on training
    data, and the student learns from both the soft labels and the hard labels
    using a weighted combination of KL divergence and cross-entropy loss.
    """

    def __init__(self) -> None:
        self._teacher_model: Any = None
        self._student_model: Any = None
        self._tokenizer: Any = None

    async def distill(
        self,
        teacher_model_id: str,
        student_model_id: str,
        dataset: list[str],
        config: dict[str, Any],
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> DistillResult:
        """Run knowledge distillation from teacher to student.

        Parameters
        ----------
        teacher_model_id:
            Identifier for the teacher model.
        student_model_id:
            Identifier for the student model (will be LoRA-adapted).
        dataset:
            List of training text samples.
        config:
            Distillation config (see DistillConfig schema).
        progress_callback:
            Optional ``(progress_0_to_1, status_message) -> None``.
        """
        temperature = config.get("temperature", 3.0)
        alpha = config.get("alpha", 0.7)
        epochs = config.get("epochs", 3)
        batch_size = config.get("batch_size", 4)
        learning_rate = config.get("learning_rate", 1e-4)
        max_seq_length = config.get("max_seq_length", 512)
        lora_rank = config.get("lora_rank", 8)
        lora_alpha_param = config.get("lora_alpha", 16)
        use_cloud = config.get("use_cloud_teacher", False)

        if not dataset:
            return DistillResult(success=False, error="No training data provided")

        # Check dependencies
        if not (_HAS_TORCH and _HAS_TRANSFORMERS and _HAS_PEFT):
            missing = []
            if not _HAS_TORCH:
                missing.append("torch")
            if not _HAS_TRANSFORMERS:
                missing.append("transformers")
            if not _HAS_PEFT:
                missing.append("peft")
            return DistillResult(
                success=False,
                error=f"Missing required dependencies: {', '.join(missing)}",
            )

        if progress_callback:
            progress_callback(0.05, "Resolving models")

        # Resolve model paths
        teacher_path = _find_model_path(teacher_model_id)
        student_path = _find_model_path(student_model_id)

        if teacher_path is None and not use_cloud:
            return DistillResult(
                success=False,
                error=f"Teacher model '{teacher_model_id}' not found locally. "
                f"Set use_cloud_teacher=True to use a cloud API.",
            )

        if student_path is None:
            return DistillResult(
                success=False,
                error=f"Student model '{student_model_id}' not found.",
            )

        # Create adapter directory
        adapter_dir = ADAPTERS_DIR / f"distill-{student_model_id}-{int(time.time())}"

        if use_cloud and teacher_path is None:
            result = await self._distill_with_cloud_teacher(
                student_path=student_path,
                student_model_id=student_model_id,
                dataset=dataset,
                adapter_dir=adapter_dir,
                temperature=temperature,
                alpha=alpha,
                epochs=epochs,
                batch_size=batch_size,
                learning_rate=learning_rate,
                max_seq_length=max_seq_length,
                lora_rank=lora_rank,
                lora_alpha_param=lora_alpha_param,
                progress_callback=progress_callback,
            )
        else:
            result = await self._distill_local(
                teacher_path=teacher_path,  # type: ignore[arg-type]
                student_path=student_path,
                teacher_model_id=teacher_model_id,
                student_model_id=student_model_id,
                dataset=dataset,
                adapter_dir=adapter_dir,
                temperature=temperature,
                alpha=alpha,
                epochs=epochs,
                batch_size=batch_size,
                learning_rate=learning_rate,
                max_seq_length=max_seq_length,
                lora_rank=lora_rank,
                lora_alpha_param=lora_alpha_param,
                progress_callback=progress_callback,
            )

        return result

    async def evaluate(
        self,
        test_data: list[str],
        teacher_model_id: str | None = None,
        student_adapter_dir: str | None = None,
    ) -> dict[str, Any]:
        """Compare student vs teacher on test data.

        Returns perplexity and loss metrics for both models.
        """
        if not test_data:
            return {"error": "No test data provided"}

        if not (_HAS_TORCH and _HAS_TRANSFORMERS):
            return {"error": "torch and transformers required for evaluation"}

        metrics: dict[str, Any] = {"num_test_samples": len(test_data)}

        # Evaluate teacher if available
        if teacher_model_id:
            teacher_path = _find_model_path(teacher_model_id)
            if teacher_path:
                teacher_ppl = await self._compute_perplexity(teacher_path, test_data)
                metrics["teacher_perplexity"] = teacher_ppl

        # Evaluate student if adapter dir provided
        if student_adapter_dir:
            student_ppl = await self._compute_perplexity(Path(student_adapter_dir), test_data)
            metrics["student_perplexity"] = student_ppl

        return metrics

    # ── Private methods ──

    async def _distill_local(
        self,
        teacher_path: Path,
        student_path: Path,
        teacher_model_id: str,
        student_model_id: str,
        dataset: list[str],
        adapter_dir: Path,
        temperature: float,
        alpha: float,
        epochs: int,
        batch_size: int,
        learning_rate: float,
        max_seq_length: int,
        lora_rank: int,
        lora_alpha_param: int,
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> DistillResult:
        """Run distillation with both models loaded locally."""

        def _blocking_distill() -> DistillResult:
            device = _select_device()
            dtype = _get_dtype(device)
            start_time = time.time()

            logger.info(
                "Starting local distillation: teacher=%s, student=%s, device=%s",
                teacher_path,
                student_path,
                device,
            )

            # ── 1. Load tokenizer (use student's tokenizer) ──
            try:
                tokenizer = AutoTokenizer.from_pretrained(str(student_path), trust_remote_code=True)
            except Exception:
                tokenizer = AutoTokenizer.from_pretrained(str(student_path), trust_remote_code=True, use_fast=False)

            if tokenizer.pad_token is None:
                tokenizer.pad_token = tokenizer.eos_token

            if progress_callback:
                progress_callback(0.10, "Loading teacher model")

            # ── 2. Load teacher model (frozen) ──
            teacher_load_kwargs: dict[str, Any] = {
                "trust_remote_code": True,
                "low_cpu_mem_usage": True,
                "torch_dtype": dtype if device == "cuda" else torch.float32,
            }
            if device == "cuda":
                teacher_load_kwargs["device_map"] = "auto"

            try:
                teacher = AutoModelForCausalLM.from_pretrained(str(teacher_path), **teacher_load_kwargs)
            except Exception as e:
                return DistillResult(success=False, error=f"Failed to load teacher: {e}")

            if device != "cuda":
                try:
                    teacher = teacher.to(device)
                except Exception:
                    teacher = teacher.to("cpu")
                    device = "cpu"

            teacher.eval()
            for param in teacher.parameters():
                param.requires_grad = False

            if progress_callback:
                progress_callback(0.20, "Loading student model")

            # ── 3. Load student model + LoRA ──
            student_load_kwargs: dict[str, Any] = {
                "trust_remote_code": True,
                "low_cpu_mem_usage": True,
                "torch_dtype": dtype if device == "cuda" else torch.float32,
            }
            if device == "cuda":
                student_load_kwargs["device_map"] = "auto"

            try:
                student = AutoModelForCausalLM.from_pretrained(str(student_path), **student_load_kwargs)
            except Exception as e:
                return DistillResult(success=False, error=f"Failed to load student: {e}")

            if device != "cuda":
                try:
                    student = student.to(device)
                except Exception:
                    student = student.to("cpu")
                    device = "cpu"

            # Read model type for LoRA target modules
            config_file = student_path / "config.json"
            model_type = ""
            if config_file.exists():
                with open(config_file) as f:
                    model_type = json.load(f).get("model_type", "")

            target_modules = _infer_target_modules(model_type)

            # Validate target modules exist
            all_module_names = {name for name, _ in student.named_modules()}
            valid_targets = [
                t for t in target_modules
                if any(n.endswith(f".{t}") or n == t for n in all_module_names)
            ]
            if not valid_targets:
                linear_names = set()
                for name, module in student.named_modules():
                    if isinstance(module, nn.Linear):
                        linear_names.add(name.split(".")[-1])
                valid_targets = list(linear_names)[:4]

            if not valid_targets:
                return DistillResult(success=False, error="No suitable LoRA target modules found in student")

            lora_config = LoraConfig(
                task_type=TaskType.CAUSAL_LM,
                r=lora_rank,
                lora_alpha=lora_alpha_param,
                lora_dropout=0.05,
                target_modules=valid_targets,
                bias="none",
            )
            student = get_peft_model(student, lora_config)
            student.train()

            trainable_params = sum(p.numel() for p in student.parameters() if p.requires_grad)
            logger.info("Student LoRA: %d trainable params, targets=%s", trainable_params, valid_targets)

            if progress_callback:
                progress_callback(0.30, "Generating soft labels from teacher")

            # ── 4. Tokenize dataset ──
            encodings = []
            for text in dataset:
                enc = tokenizer(
                    text,
                    truncation=True,
                    max_length=max_seq_length,
                    padding="max_length",
                    return_tensors="pt",
                )
                encodings.append(enc)

            if not encodings:
                return DistillResult(success=False, error="No valid samples after tokenization")

            # ── 5. Generate teacher soft labels ──
            teacher_logits_cache: list[torch.Tensor] = []

            with torch.no_grad():
                for idx, enc in enumerate(encodings):
                    input_ids = enc["input_ids"].to(device)
                    attention_mask = enc["attention_mask"].to(device)

                    outputs = teacher(input_ids=input_ids, attention_mask=attention_mask)
                    # Store softened logits (on CPU to save GPU memory)
                    soft_logits = (outputs.logits / temperature).cpu()
                    teacher_logits_cache.append(soft_logits)

                    if progress_callback and idx % 10 == 0:
                        pct = 0.30 + (idx / len(encodings)) * 0.15
                        progress_callback(min(pct, 0.45), f"Generating soft labels ({idx + 1}/{len(encodings)})")

            # Free teacher from GPU
            del teacher
            if device == "cuda":
                torch.cuda.empty_cache()

            if progress_callback:
                progress_callback(0.45, "Starting distillation training")

            # ── 6. Distillation training loop ──
            optimizer = torch.optim.AdamW(student.parameters(), lr=learning_rate, weight_decay=0.01)

            step_losses: list[float] = []
            kl_losses: list[float] = []
            ce_losses: list[float] = []
            total_steps = 0

            for epoch in range(epochs):
                rng = np.random.default_rng(seed=epoch)
                indices = rng.permutation(len(encodings))
                epoch_loss = 0.0
                num_batches = 0

                for batch_start in range(0, len(indices), batch_size):
                    batch_idx = indices[batch_start : batch_start + batch_size]
                    batch_loss = torch.tensor(0.0, device=device, requires_grad=True)

                    for i in batch_idx:
                        enc = encodings[i]
                        input_ids = enc["input_ids"].to(device)
                        attention_mask = enc["attention_mask"].to(device)
                        labels = input_ids.clone()
                        labels[labels == tokenizer.pad_token_id] = -100

                        # Student forward pass
                        student_outputs = student(
                            input_ids=input_ids,
                            attention_mask=attention_mask,
                            labels=labels,
                        )

                        # Hard label loss (cross-entropy from student)
                        ce_loss = student_outputs.loss

                        # Soft label loss (KL divergence)
                        teacher_soft = teacher_logits_cache[i].to(device)
                        student_logits = student_outputs.logits / temperature

                        # KL divergence on softened distributions
                        teacher_probs = F.log_softmax(teacher_soft, dim=-1)
                        student_log_probs = F.log_softmax(student_logits, dim=-1)

                        # Trim to same size if needed
                        min_vocab = min(teacher_probs.shape[-1], student_log_probs.shape[-1])
                        teacher_probs_trimmed = teacher_probs[..., :min_vocab]
                        student_log_probs_trimmed = student_log_probs[..., :min_vocab]

                        kl_loss = F.kl_div(
                            student_log_probs_trimmed,
                            teacher_probs_trimmed,
                            log_target=True,
                            reduction="batchmean",
                        ) * (temperature ** 2)

                        # Combined loss
                        combined = alpha * kl_loss + (1.0 - alpha) * ce_loss
                        batch_loss = batch_loss + combined

                    # Average over batch
                    batch_loss = batch_loss / len(batch_idx)

                    optimizer.zero_grad()
                    batch_loss.backward()
                    torch.nn.utils.clip_grad_norm_(student.parameters(), max_norm=1.0)
                    optimizer.step()

                    loss_val = batch_loss.item()
                    step_losses.append(loss_val)
                    epoch_loss += loss_val
                    num_batches += 1
                    total_steps += 1

                avg_epoch_loss = epoch_loss / max(num_batches, 1)
                logger.info("Epoch %d/%d — avg_loss: %.6f", epoch + 1, epochs, avg_epoch_loss)

                if progress_callback:
                    pct = 0.45 + ((epoch + 1) / epochs) * 0.40
                    progress_callback(min(pct, 0.85), f"Distillation epoch {epoch + 1}/{epochs}")

            # ── 7. Save student adapter ──
            adapter_dir.mkdir(parents=True, exist_ok=True)
            student.save_pretrained(str(adapter_dir))

            # Save distillation config
            distill_config = {
                "studiomc_format": "distilled_lora",
                "teacher_model_id": teacher_model_id,
                "student_model_id": student_model_id,
                "temperature": temperature,
                "alpha": alpha,
                "lora_rank": lora_rank,
                "lora_alpha": lora_alpha_param,
                "target_modules": valid_targets,
                "num_samples": len(dataset),
                "epochs": epochs,
                "total_steps": total_steps,
                "final_loss": step_losses[-1] if step_losses else None,
                "trainable_params": trainable_params,
                "device": device,
                "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            }

            config_path = adapter_dir / "adapter_config.json"
            if config_path.exists():
                with open(config_path) as f:
                    existing_cfg = json.load(f)
                existing_cfg.update(distill_config)
                distill_config = existing_cfg
            config_path.write_text(json.dumps(distill_config, indent=2))

            elapsed = time.time() - start_time

            # Cleanup
            del student, optimizer
            if device == "cuda":
                torch.cuda.empty_cache()

            return DistillResult(
                success=True,
                adapter_dir=str(adapter_dir),
                num_samples=len(dataset),
                epochs_completed=epochs,
                final_loss=step_losses[-1] if step_losses else None,
                metrics={
                    "method": "local_distillation",
                    "temperature": temperature,
                    "alpha": alpha,
                    "total_steps": total_steps,
                    "final_loss": step_losses[-1] if step_losses else None,
                    "avg_loss": sum(step_losses) / len(step_losses) if step_losses else None,
                    "trainable_params": trainable_params,
                    "device": device,
                    "elapsed_seconds": round(elapsed, 1),
                    "step_losses_last10": step_losses[-10:],
                },
            )

        return await asyncio.to_thread(_blocking_distill)

    async def _distill_with_cloud_teacher(
        self,
        student_path: Path,
        student_model_id: str,
        dataset: list[str],
        adapter_dir: Path,
        temperature: float,
        alpha: float,
        epochs: int,
        batch_size: int,
        learning_rate: float,
        max_seq_length: int,
        lora_rank: int,
        lora_alpha_param: int,
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> DistillResult:
        """Distillation using a cloud API as the teacher.

        The cloud teacher generates completions which serve as soft targets.
        Since we don't have access to the cloud model's logits, we use the
        generated text as "pseudo-labels" and train the student to reproduce
        them — effectively sequence-level distillation.
        """
        import httpx

        from common.config import INFERENCE_PORT

        if progress_callback:
            progress_callback(0.10, "Generating pseudo-labels from cloud teacher")

        # Generate teacher outputs via the inference API
        pseudo_labels: list[tuple[str, str]] = []  # (input, teacher_output)

        async with httpx.AsyncClient(timeout=120.0) as client:
            for idx, text in enumerate(dataset):
                try:
                    resp = await client.post(
                        f"http://127.0.0.1:{INFERENCE_PORT}/v1/chat/completions",
                        json={
                            "messages": [
                                {"role": "user", "content": f"Continue the following text:\n\n{text[:500]}"}
                            ],
                            "temperature": 0.3,
                            "max_tokens": 256,
                        },
                    )
                    resp.raise_for_status()
                    data = resp.json()
                    teacher_output = data["choices"][0]["message"]["content"]
                    pseudo_labels.append((text, teacher_output))
                except Exception as e:
                    logger.warning("Cloud teacher failed for sample %d: %s", idx, e)
                    continue

                if progress_callback and idx % 5 == 0:
                    pct = 0.10 + (idx / len(dataset)) * 0.20
                    progress_callback(min(pct, 0.30), f"Generating pseudo-labels ({idx + 1}/{len(dataset)})")

        if not pseudo_labels:
            return DistillResult(success=False, error="Cloud teacher failed to generate any pseudo-labels")

        if progress_callback:
            progress_callback(0.35, "Training student on pseudo-labels")

        # Now train student on the pseudo-labeled data using standard LoRA fine-tuning
        from training.lora_trainer import train_adapter

        # Format as instruction-tuning text
        training_text_parts: list[str] = []
        for inp, out in pseudo_labels:
            training_text_parts.append(f"Q: {inp[:300]}\nA: {out}")

        training_text = "\n\n".join(training_text_parts)

        result = await train_adapter(
            adapter_dir=adapter_dir,
            base_model_id=student_model_id,
            training_text=training_text,
            source_type="distillation",
            max_steps=epochs * len(pseudo_labels) // batch_size,
            learning_rate=learning_rate,
            lora_rank=lora_rank,
            lora_alpha=lora_alpha_param,
            max_seq_length=max_seq_length,
        )

        if progress_callback:
            progress_callback(0.90, "Cloud distillation complete")

        return DistillResult(
            success=result.success,
            adapter_dir=str(adapter_dir),
            num_samples=len(pseudo_labels),
            epochs_completed=epochs,
            final_loss=result.final_loss,
            error=result.error,
            metrics={
                "method": "cloud_sequence_distillation",
                "num_pseudo_labels": len(pseudo_labels),
                "format": result.format,
                "num_steps": result.num_steps,
                "final_loss": result.final_loss,
            },
        )

    async def _compute_perplexity(
        self,
        model_path: Path,
        test_texts: list[str],
        max_samples: int = 50,
    ) -> float:
        """Compute perplexity of a model on test texts."""

        def _blocking_eval() -> float:
            device = _select_device()

            tokenizer = AutoTokenizer.from_pretrained(str(model_path), trust_remote_code=True)
            if tokenizer.pad_token is None:
                tokenizer.pad_token = tokenizer.eos_token

            model = AutoModelForCausalLM.from_pretrained(
                str(model_path),
                trust_remote_code=True,
                low_cpu_mem_usage=True,
                torch_dtype=_get_dtype(device) if device == "cuda" else torch.float32,
            )

            if device != "cuda":
                try:
                    model = model.to(device)
                except Exception:
                    model = model.to("cpu")

            model.eval()
            total_loss = 0.0
            num_samples = 0

            with torch.no_grad():
                for text in test_texts[:max_samples]:
                    enc = tokenizer(text, truncation=True, max_length=512, return_tensors="pt")
                    input_ids = enc["input_ids"].to(model.device)
                    labels = input_ids.clone()

                    outputs = model(input_ids=input_ids, labels=labels)
                    total_loss += outputs.loss.item()
                    num_samples += 1

            del model
            if device == "cuda":
                torch.cuda.empty_cache()

            avg_loss = total_loss / max(num_samples, 1)
            return float(np.exp(avg_loss))

        return await asyncio.to_thread(_blocking_eval)


# ── Module-level singleton ───────────────────────────────────────

_distiller_instance: KnowledgeDistiller | None = None


def get_distiller() -> KnowledgeDistiller:
    """Return a singleton KnowledgeDistiller."""
    global _distiller_instance
    if _distiller_instance is None:
        _distiller_instance = KnowledgeDistiller()
    return _distiller_instance
