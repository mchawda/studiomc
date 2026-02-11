"""Real LoRA adapter trainer using PEFT + PyTorch.

Handles the full pipeline:
  1. Resolve a transformers-compatible base model
  2. Load model + tokenizer
  3. Apply LoRA via PEFT
  4. Train with a manual PyTorch loop (lightweight, no HF Trainer)
  5. Save adapter in PEFT format

Falls back to a prompt-injection adapter (structured JSONL for RAG-style
retrieval at inference time) when real LoRA training is not possible
(e.g. no compatible model, OOM, missing dependencies).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import platform
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from training.tokenizer_utils import TrainingSample, format_training_samples, samples_to_jsonl

logger = logging.getLogger("training.lora_trainer")

# ---------------------------------------------------------------------------
# Optional dependency imports — fail gracefully
# ---------------------------------------------------------------------------

_HAS_TORCH = False
_HAS_PEFT = False
_HAS_TRANSFORMERS = False

try:
    import torch

    _HAS_TORCH = True
except ImportError:
    torch = None  # type: ignore[assignment]

try:
    import transformers  # noqa: F811
    from transformers import AutoModelForCausalLM, AutoTokenizer, AutoConfig

    _HAS_TRANSFORMERS = True
except ImportError:
    transformers = None  # type: ignore[assignment]

try:
    from peft import LoraConfig, get_peft_model, TaskType

    _HAS_PEFT = True
except ImportError:
    pass


# ---------------------------------------------------------------------------
# Training result
# ---------------------------------------------------------------------------


@dataclass
class TrainingResult:
    """Outcome of a training attempt."""

    success: bool
    format: str  # "lora_peft" | "prompt_injection"
    adapter_dir: str
    num_samples: int
    num_steps: int
    final_loss: float | None = None
    error: str | None = None
    metrics: dict | None = None


# ---------------------------------------------------------------------------
# LoRA target-module mapping
# ---------------------------------------------------------------------------

# Map model_type (from config.json) to the linear layers LoRA should wrap.
_TARGET_MODULES_MAP: dict[str, list[str]] = {
    # LLaMA family (incl. Mistral, Mixtral, CodeLlama, Yi, etc.)
    "llama": ["q_proj", "k_proj", "v_proj", "o_proj"],
    "mistral": ["q_proj", "k_proj", "v_proj", "o_proj"],
    "mixtral": ["q_proj", "k_proj", "v_proj", "o_proj"],
    # GPT-OSS (this project's own architecture)
    "gpt_oss": ["q_proj", "k_proj", "v_proj", "o_proj"],
    # GPT-2 / GPT-Neo
    "gpt2": ["c_attn", "c_proj"],
    "gpt_neo": ["q_proj", "k_proj", "v_proj"],
    "gpt_neox": ["query_key_value", "dense"],
    # Falcon
    "falcon": ["query_key_value", "dense"],
    # Phi
    "phi": ["q_proj", "k_proj", "v_proj", "dense"],
    "phi3": ["qkv_proj", "o_proj"],
    # Gemma
    "gemma": ["q_proj", "k_proj", "v_proj", "o_proj"],
    "gemma2": ["q_proj", "k_proj", "v_proj", "o_proj"],
    # Qwen
    "qwen2": ["q_proj", "k_proj", "v_proj", "o_proj"],
    # StarCoder
    "starcoder": ["c_attn", "c_proj"],
}

# Fallback that works for most modern transformer architectures
_DEFAULT_TARGET_MODULES = ["q_proj", "k_proj", "v_proj", "o_proj"]


def _infer_target_modules(model_type: str | None) -> list[str]:
    """Return the best target-module list for the given model type."""
    if model_type and model_type in _TARGET_MODULES_MAP:
        return _TARGET_MODULES_MAP[model_type]
    return _DEFAULT_TARGET_MODULES


# ---------------------------------------------------------------------------
# Model resolution — find a transformers-compatible model on disk
# ---------------------------------------------------------------------------


def _find_model_path(base_model_id: str) -> Path | None:
    """Search for a transformers-compatible model directory.

    Search order:
      1. ~/.studiomc/models/<base_model_id>/  (user-downloaded HF models)
      2. <project>/models/*/                   (project-bundled models)
      3. Ollama model directory                (GGUF — not compatible, skip)

    A directory is "compatible" if it contains a config.json with
    an ``architectures`` or ``model_type`` key.
    """
    from common.config import MODELS_DIR

    candidates: list[Path] = []

    # 1. User data dir — exact match
    user_model_dir = MODELS_DIR / base_model_id
    if user_model_dir.is_dir():
        candidates.append(user_model_dir)

    # Also scan all subdirs under MODELS_DIR
    if MODELS_DIR.is_dir():
        for child in MODELS_DIR.iterdir():
            if child.is_dir() and child not in candidates:
                candidates.append(child)

    # 2. Project models/ directory (sibling of services/)
    project_root = Path(__file__).resolve().parent.parent.parent
    project_models = project_root / "models"
    if project_models.is_dir():
        for child in sorted(project_models.iterdir()):
            if child.is_dir() and child not in candidates:
                candidates.append(child)

    # Evaluate each candidate
    for path in candidates:
        config_file = path / "config.json"
        if not config_file.exists():
            continue
        try:
            with open(config_file) as f:
                cfg = json.load(f)
            # Must have architectures or model_type
            if cfg.get("architectures") or cfg.get("model_type"):
                # Reject pure GGUF directories (no safetensors / bin)
                has_weights = any(
                    path.glob("*.safetensors")
                ) or any(
                    path.glob("*.bin")
                ) or (path / "model.safetensors.index.json").exists()
                if has_weights:
                    logger.info("Found compatible model at %s", path)
                    return path
        except (json.JSONDecodeError, OSError):
            continue

    return None


# ---------------------------------------------------------------------------
# Device helpers
# ---------------------------------------------------------------------------


def _select_device() -> str:
    """Pick the best available device for training."""
    if not _HAS_TORCH:
        return "cpu"

    # CUDA
    if torch.cuda.is_available():
        return "cuda"

    # Apple Silicon MPS
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"

    return "cpu"


def _get_dtype(device: str) -> "torch.dtype":
    """Select an appropriate dtype for the device."""
    if device == "cuda":
        if torch.cuda.is_bf16_supported():
            return torch.bfloat16
        return torch.float16
    if device == "mps":
        return torch.float32  # MPS has limited float16 support for training
    return torch.float32


# ---------------------------------------------------------------------------
# Prompt-injection fallback
# ---------------------------------------------------------------------------


def _save_prompt_injection_adapter(
    adapter_dir: Path,
    samples: list[TrainingSample],
    base_model_id: str,
    source_type: str,
) -> TrainingResult:
    """Save training data as a prompt-injection adapter.

    This creates a structured JSONL file that the inference engine can
    use for RAG-style example injection at generation time — the model
    is prompted with relevant examples from the training data.
    """
    adapter_dir.mkdir(parents=True, exist_ok=True)

    # Save JSONL training data
    jsonl_path = adapter_dir / "training_samples.jsonl"
    jsonl_path.write_text(samples_to_jsonl(samples), encoding="utf-8")

    # Save adapter config
    config = {
        "adapter_id": adapter_dir.name,
        "base_model_id": base_model_id,
        "source_type": source_type,
        "format": "prompt_injection",
        "num_samples": len(samples),
        "description": (
            "Prompt-injection adapter: training examples are injected as "
            "context during inference (RAG-style retrieval)."
        ),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    config_path = adapter_dir / "adapter_config.json"
    config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    # Also save raw training text for reference
    raw_text_path = adapter_dir / "training_data.txt"
    prompt_texts = [s.to_prompt() for s in samples]
    raw_text_path.write_text("\n\n---\n\n".join(prompt_texts), encoding="utf-8")

    logger.info(
        "Saved prompt-injection adapter with %d samples to %s",
        len(samples),
        adapter_dir,
    )

    return TrainingResult(
        success=True,
        format="prompt_injection",
        adapter_dir=str(adapter_dir),
        num_samples=len(samples),
        num_steps=0,
        final_loss=None,
        metrics={"num_samples": len(samples)},
    )


# ---------------------------------------------------------------------------
# Real LoRA training
# ---------------------------------------------------------------------------


async def _train_lora(
    model_path: Path,
    samples: list[TrainingSample],
    adapter_dir: Path,
    base_model_id: str,
    source_type: str,
    max_steps: int = 50,
    learning_rate: float = 2e-4,
    lora_rank: int = 8,
    lora_alpha: int = 16,
    lora_dropout: float = 0.05,
    max_seq_length: int = 512,
    batch_size: int = 1,
    progress_callback: Callable[[float, int], None] | None = None,
) -> TrainingResult:
    """Run actual LoRA fine-tuning in a thread pool (CPU-bound work)."""

    def _blocking_train() -> TrainingResult:
        device_name = _select_device()
        dtype = _get_dtype(device_name)

        # Reduce steps for CPU to keep training time reasonable
        effective_steps = max_steps
        if device_name == "cpu":
            effective_steps = min(max_steps, 20)
            logger.info("CPU training: limiting to %d steps", effective_steps)

        logger.info(
            "Starting LoRA training: device=%s, dtype=%s, steps=%d, rank=%d",
            device_name,
            dtype,
            effective_steps,
            lora_rank,
        )

        # ── 1. Load model config to determine architecture ──────────────
        config_file = model_path / "config.json"
        with open(config_file) as f:
            model_config = json.load(f)

        model_type = model_config.get("model_type", "")
        target_modules = _infer_target_modules(model_type)
        logger.info("Model type: %s, target modules: %s", model_type, target_modules)

        # ── 2. Load tokenizer ───────────────────────────────────────────
        try:
            tokenizer = AutoTokenizer.from_pretrained(
                str(model_path),
                trust_remote_code=True,
                use_fast=True,
            )
        except Exception as e:
            logger.warning("Fast tokenizer failed (%s), trying slow", e)
            tokenizer = AutoTokenizer.from_pretrained(
                str(model_path),
                trust_remote_code=True,
                use_fast=False,
            )

        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token

        # ── 3. Load base model ──────────────────────────────────────────
        load_kwargs: dict = {
            "trust_remote_code": True,
            "low_cpu_mem_usage": True,
        }

        # For GPU, try to load in reduced precision
        if device_name == "cuda":
            load_kwargs["torch_dtype"] = dtype
            load_kwargs["device_map"] = "auto"
        elif device_name == "mps":
            load_kwargs["torch_dtype"] = torch.float32
        else:
            load_kwargs["torch_dtype"] = torch.float32

        # Ignore quantization config from the original model —
        # we load in float/half for LoRA training
        load_kwargs["ignore_mismatched_sizes"] = True

        try:
            # First try loading the config to check if quantization
            # config needs to be removed
            auto_config = AutoConfig.from_pretrained(
                str(model_path),
                trust_remote_code=True,
            )
            # Remove quantization config if present — we want to load
            # in native precision for LoRA
            if hasattr(auto_config, "quantization_config"):
                auto_config.quantization_config = None

            load_kwargs["config"] = auto_config

            model = AutoModelForCausalLM.from_pretrained(
                str(model_path),
                **load_kwargs,
            )
        except Exception as e:
            error_msg = str(e)
            logger.error("Failed to load model: %s", error_msg)
            raise RuntimeError(f"Cannot load model from {model_path}: {error_msg}") from e

        # Move to device if not already there
        if device_name != "cuda":  # device_map="auto" handles CUDA
            try:
                model = model.to(device_name)
            except Exception as e:
                logger.warning("Failed to move model to %s: %s, falling back to CPU", device_name, e)
                device_name = "cpu"
                model = model.to("cpu")

        # ── 4. Apply LoRA ───────────────────────────────────────────────
        # Verify target modules exist in the model
        all_module_names = {name for name, _ in model.named_modules()}
        valid_targets = []
        for target in target_modules:
            # Check if any module name ends with the target
            if any(name.endswith(f".{target}") or name == target for name in all_module_names):
                valid_targets.append(target)

        if not valid_targets:
            # Last resort: try to find any Linear layers
            linear_names = set()
            for name, module in model.named_modules():
                if isinstance(module, torch.nn.Linear):
                    short_name = name.split(".")[-1]
                    linear_names.add(short_name)
            valid_targets = list(linear_names)[:4]  # Take up to 4
            logger.warning("No standard targets found, using discovered: %s", valid_targets)

        if not valid_targets:
            raise RuntimeError("No suitable linear layers found for LoRA adaptation")

        lora_config = LoraConfig(
            task_type=TaskType.CAUSAL_LM,
            r=lora_rank,
            lora_alpha=lora_alpha,
            lora_dropout=lora_dropout,
            target_modules=valid_targets,
            bias="none",
        )

        model = get_peft_model(model, lora_config)
        trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
        total_params = sum(p.numel() for p in model.parameters())
        logger.info(
            "LoRA applied: %d trainable / %d total params (%.2f%%)",
            trainable_params,
            total_params,
            100 * trainable_params / total_params,
        )

        model.train()

        # ── 5. Prepare training data ────────────────────────────────────
        train_texts = [s.to_prompt(include_response=True) for s in samples]

        # Tokenize all samples
        encodings = []
        for text in train_texts:
            enc = tokenizer(
                text,
                truncation=True,
                max_length=max_seq_length,
                padding="max_length",
                return_tensors="pt",
            )
            encodings.append(enc)

        if not encodings:
            raise RuntimeError("No valid training samples after tokenization")

        # ── 6. Training loop ────────────────────────────────────────────
        optimizer = torch.optim.AdamW(
            model.parameters(),
            lr=learning_rate,
            weight_decay=0.01,
        )

        total_loss = 0.0
        step_losses: list[float] = []
        start_time = time.time()

        for step in range(1, effective_steps + 1):
            # Cycle through training samples
            sample_idx = (step - 1) % len(encodings)
            batch = encodings[sample_idx]

            input_ids = batch["input_ids"].to(device_name)
            attention_mask = batch["attention_mask"].to(device_name)
            labels = input_ids.clone()

            # Mask padding tokens in labels
            labels[labels == tokenizer.pad_token_id] = -100

            optimizer.zero_grad()

            try:
                outputs = model(
                    input_ids=input_ids,
                    attention_mask=attention_mask,
                    labels=labels,
                )
                loss = outputs.loss
            except RuntimeError as e:
                if "out of memory" in str(e).lower():
                    logger.error("OOM at step %d", step)
                    if device_name == "cuda":
                        torch.cuda.empty_cache()
                    raise
                raise

            loss.backward()
            # Gradient clipping
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()

            loss_val = loss.item()
            total_loss += loss_val
            step_losses.append(loss_val)

            # Report progress
            if progress_callback is not None:
                elapsed = time.time() - start_time
                eta = int((elapsed / step) * (effective_steps - step)) if step > 0 else 0
                # Progress: 15% (start) to 95% (end of training)
                pct = 15.0 + (step / effective_steps) * 80.0
                progress_callback(pct, eta)

            if step % 5 == 0 or step == effective_steps:
                avg_loss = total_loss / step
                logger.info(
                    "Step %d/%d — loss: %.4f, avg_loss: %.4f",
                    step,
                    effective_steps,
                    loss_val,
                    avg_loss,
                )

        # ── 7. Save adapter ─────────────────────────────────────────────
        adapter_dir.mkdir(parents=True, exist_ok=True)

        # Save PEFT adapter weights
        model.save_pretrained(str(adapter_dir))

        # Also save training samples for reference
        jsonl_path = adapter_dir / "training_samples.jsonl"
        jsonl_path.write_text(samples_to_jsonl(samples), encoding="utf-8")

        # Update adapter_config.json with our metadata
        peft_config_path = adapter_dir / "adapter_config.json"
        if peft_config_path.exists():
            with open(peft_config_path) as f:
                adapter_cfg = json.load(f)
        else:
            adapter_cfg = {}

        adapter_cfg.update({
            "studiomc_format": "lora_peft",
            "base_model_id": base_model_id,
            "source_type": source_type,
            "model_path": str(model_path),
            "model_type": model_type,
            "lora_rank": lora_rank,
            "lora_alpha": lora_alpha,
            "lora_dropout": lora_dropout,
            "target_modules": valid_targets,
            "num_samples": len(samples),
            "num_steps": effective_steps,
            "final_loss": step_losses[-1] if step_losses else None,
            "avg_loss": total_loss / effective_steps if effective_steps > 0 else None,
            "device": device_name,
            "trainable_params": trainable_params,
            "total_params": total_params,
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        })
        peft_config_path.write_text(json.dumps(adapter_cfg, indent=2), encoding="utf-8")

        # Clean up GPU memory
        del model, optimizer
        if device_name == "cuda" and torch is not None:
            torch.cuda.empty_cache()

        final_loss = step_losses[-1] if step_losses else None
        logger.info(
            "LoRA training complete: %d steps, final_loss=%.4f, saved to %s",
            effective_steps,
            final_loss or 0.0,
            adapter_dir,
        )

        return TrainingResult(
            success=True,
            format="lora_peft",
            adapter_dir=str(adapter_dir),
            num_samples=len(samples),
            num_steps=effective_steps,
            final_loss=final_loss,
            metrics={
                "trainable_params": trainable_params,
                "total_params": total_params,
                "final_loss": final_loss,
                "avg_loss": total_loss / effective_steps if effective_steps > 0 else None,
                "device": device_name,
                "step_losses": step_losses[-10:],  # Last 10 losses
            },
        )

    # Run the blocking training in a thread pool so it doesn't block the event loop
    return await asyncio.to_thread(_blocking_train)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


async def train_adapter(
    adapter_dir: Path,
    base_model_id: str,
    training_text: str,
    source_type: str,
    max_steps: int = 50,
    learning_rate: float = 2e-4,
    lora_rank: int = 8,
    lora_alpha: int = 16,
    lora_dropout: float = 0.05,
    max_seq_length: int = 512,
    progress_callback: Callable[[float, int], None] | None = None,
) -> TrainingResult:
    """Train a LoRA adapter, falling back to prompt-injection if needed.

    Parameters
    ----------
    adapter_dir:
        Directory to save the adapter files.
    base_model_id:
        Identifier for the base model.
    training_text:
        Raw training text (Q&A pairs, facts, document content, etc.).
    source_type:
        One of "collection", "extract_paste", "extract_file".
    max_steps:
        Maximum number of training steps.
    learning_rate:
        Learning rate for the optimizer.
    lora_rank:
        LoRA rank (r parameter).
    lora_alpha:
        LoRA alpha scaling factor.
    lora_dropout:
        Dropout probability for LoRA layers.
    max_seq_length:
        Maximum token sequence length for training samples.
    progress_callback:
        Optional ``(progress_percent, eta_seconds) -> None`` callback.

    Returns
    -------
    TrainingResult with ``format`` set to ``"lora_peft"`` or ``"prompt_injection"``.
    """
    # Step 1: Parse training text into samples
    samples = format_training_samples(training_text)
    if not samples:
        return TrainingResult(
            success=False,
            format="none",
            adapter_dir=str(adapter_dir),
            num_samples=0,
            num_steps=0,
            error="No usable training samples could be parsed from the input text.",
        )

    logger.info("Prepared %d training samples from %d chars of text", len(samples), len(training_text))

    # Step 2: Check if real LoRA training is possible
    can_do_lora = _HAS_TORCH and _HAS_PEFT and _HAS_TRANSFORMERS
    if not can_do_lora:
        missing = []
        if not _HAS_TORCH:
            missing.append("torch")
        if not _HAS_PEFT:
            missing.append("peft")
        if not _HAS_TRANSFORMERS:
            missing.append("transformers")
        logger.warning(
            "LoRA training unavailable — missing dependencies: %s. "
            "Falling back to prompt-injection adapter.",
            ", ".join(missing),
        )
        if progress_callback:
            progress_callback(50.0, 5)
        result = _save_prompt_injection_adapter(adapter_dir, samples, base_model_id, source_type)
        if progress_callback:
            progress_callback(95.0, 0)
        return result

    # Step 3: Find a compatible model
    model_path = _find_model_path(base_model_id)
    if model_path is None:
        logger.warning(
            "No transformers-compatible model found for '%s'. "
            "Falling back to prompt-injection adapter.",
            base_model_id,
        )
        if progress_callback:
            progress_callback(50.0, 5)
        result = _save_prompt_injection_adapter(adapter_dir, samples, base_model_id, source_type)
        if progress_callback:
            progress_callback(95.0, 0)
        return result

    # Step 4: Attempt real LoRA training
    try:
        result = await _train_lora(
            model_path=model_path,
            samples=samples,
            adapter_dir=adapter_dir,
            base_model_id=base_model_id,
            source_type=source_type,
            max_steps=max_steps,
            learning_rate=learning_rate,
            lora_rank=lora_rank,
            lora_alpha=lora_alpha,
            lora_dropout=lora_dropout,
            max_seq_length=max_seq_length,
            progress_callback=progress_callback,
        )
        return result

    except RuntimeError as e:
        error_msg = str(e)
        is_oom = "out of memory" in error_msg.lower()
        is_arch = "architecture" in error_msg.lower() or "not supported" in error_msg.lower()

        if is_oom:
            logger.warning("OOM during LoRA training — falling back to prompt-injection adapter")
        elif is_arch:
            logger.warning(
                "Unsupported architecture for LoRA — falling back to prompt-injection adapter: %s",
                error_msg,
            )
        else:
            logger.warning("LoRA training failed — falling back to prompt-injection adapter: %s", error_msg)

        # Clean up any partial adapter files
        if adapter_dir.exists():
            for f in adapter_dir.iterdir():
                try:
                    f.unlink()
                except OSError:
                    pass

        if progress_callback:
            progress_callback(50.0, 5)

        result = _save_prompt_injection_adapter(adapter_dir, samples, base_model_id, source_type)
        result.error = f"LoRA failed ({error_msg}), used prompt-injection fallback"
        if progress_callback:
            progress_callback(95.0, 0)
        return result

    except Exception as e:
        logger.exception("Unexpected error during LoRA training — using prompt-injection fallback")

        # Clean up any partial adapter files
        if adapter_dir.exists():
            for f in adapter_dir.iterdir():
                try:
                    f.unlink()
                except OSError:
                    pass

        if progress_callback:
            progress_callback(50.0, 5)

        result = _save_prompt_injection_adapter(adapter_dir, samples, base_model_id, source_type)
        result.error = f"Training error ({e}), used prompt-injection fallback"
        if progress_callback:
            progress_callback(95.0, 0)
        return result
