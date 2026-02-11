# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Context Distillation — train models to reason over compressed context.

Phase 4: Builds on CLaRa compression and LoRA training to teach a model
to produce the same quality answers from compressed context as from full
context.

Pipeline:
  1. For each document, generate Q&A pairs using the model with full context
  2. Compress the context using CLaRa
  3. Train the model (via LoRA) to answer the same questions from compressed context
  4. This teaches the model to "understand" compressed representations

Uses existing LoRA training infrastructure for the fine-tuning step.
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

from common.config import ADAPTERS_DIR, INFERENCE_PORT, MODELS_DIR
from common.database import Database

from clara.compressor import encode_texts, get_dims

logger = logging.getLogger("training.context_distiller")

# ── Optional dependency detection ────────────────────────────────

_HAS_TORCH = False
_HAS_TRANSFORMERS = False
_HAS_PEFT = False

try:
    import torch
    import torch.nn.functional as F

    _HAS_TORCH = True
except ImportError:
    torch = None  # type: ignore[assignment]

try:
    from transformers import AutoModelForCausalLM, AutoTokenizer

    _HAS_TRANSFORMERS = True
except ImportError:
    pass

try:
    from peft import LoraConfig, get_peft_model, TaskType

    _HAS_PEFT = True
except ImportError:
    pass


# ── Result dataclass ─────────────────────────────────────────────


@dataclass
class ContextDistillResult:
    """Outcome of a context distillation run."""

    success: bool
    adapter_dir: str = ""
    num_documents: int = 0
    num_qa_pairs: int = 0
    epochs_completed: int = 0
    final_loss: float | None = None
    error: str | None = None
    metrics: dict[str, Any] = field(default_factory=dict)


# ── Device helpers ───────────────────────────────────────────────


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


# ── Q&A generation helpers ───────────────────────────────────────


async def _generate_qa_pairs_local(
    model_path: Path,
    doc_texts: list[str],
    num_pairs_per_doc: int,
    progress_callback: Callable[[float, str], None] | None = None,
) -> list[dict[str, str]]:
    """Generate Q&A pairs using a local model with full document context.

    Returns list of {"context": full_text, "question": q, "answer": a}.
    """

    def _blocking_generate() -> list[dict[str, str]]:
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

        qa_pairs: list[dict[str, str]] = []

        for doc_idx, text in enumerate(doc_texts):
            # Truncate long documents to fit in context
            max_context_chars = 2000
            context = text[:max_context_chars]

            prompt = (
                f"Given the following document, generate {num_pairs_per_doc} "
                f"question-answer pairs. Format each as:\n"
                f"Q: [question]\n"
                f"A: [answer]\n\n"
                f"Document:\n{context}\n\n"
                f"Question-Answer pairs:\n"
            )

            enc = tokenizer(prompt, truncation=True, max_length=1024, return_tensors="pt")
            input_ids = enc["input_ids"].to(model.device)

            with torch.no_grad():
                try:
                    output_ids = model.generate(
                        input_ids,
                        max_new_tokens=512,
                        temperature=0.7,
                        do_sample=True,
                        pad_token_id=tokenizer.pad_token_id,
                    )
                except Exception as e:
                    logger.warning("Generation failed for doc %d: %s", doc_idx, e)
                    continue

            output_text = tokenizer.decode(output_ids[0][input_ids.shape[1]:], skip_special_tokens=True)

            # Parse Q&A pairs from generated text
            import re

            qa_pattern = re.compile(
                r"Q:\s*(.+?)(?:\n|\r\n?)A:\s*(.+?)(?=\nQ:|\Z)",
                re.DOTALL | re.IGNORECASE,
            )

            for match in qa_pattern.finditer(output_text):
                question = match.group(1).strip()
                answer = match.group(2).strip()
                if question and answer and len(question) > 5 and len(answer) > 5:
                    qa_pairs.append({
                        "context": context,
                        "question": question,
                        "answer": answer,
                    })

            if progress_callback:
                pct = 0.10 + ((doc_idx + 1) / len(doc_texts)) * 0.25
                progress_callback(min(pct, 0.35), f"Generating Q&A pairs ({doc_idx + 1}/{len(doc_texts)})")

        # Clean up
        del model
        if device == "cuda":
            torch.cuda.empty_cache()

        return qa_pairs

    return await asyncio.to_thread(_blocking_generate)


async def _generate_qa_pairs_api(
    doc_texts: list[str],
    num_pairs_per_doc: int,
    progress_callback: Callable[[float, str], None] | None = None,
) -> list[dict[str, str]]:
    """Generate Q&A pairs via the inference API (for models served by llama.cpp etc.)."""
    import httpx

    qa_pairs: list[dict[str, str]] = []

    async with httpx.AsyncClient(timeout=120.0) as client:
        for doc_idx, text in enumerate(doc_texts):
            context = text[:2000]
            prompt = (
                f"Given the following document, generate {num_pairs_per_doc} "
                f"question-answer pairs. Format each as:\n"
                f"Q: [question]\n"
                f"A: [answer]\n\n"
                f"Document:\n{context}\n\n"
                f"Question-Answer pairs:\n"
            )

            try:
                resp = await client.post(
                    f"http://127.0.0.1:{INFERENCE_PORT}/v1/chat/completions",
                    json={
                        "messages": [{"role": "user", "content": prompt}],
                        "temperature": 0.7,
                        "max_tokens": 512,
                    },
                )
                resp.raise_for_status()
                data = resp.json()
                output_text = data["choices"][0]["message"]["content"]

                import re

                qa_pattern = re.compile(
                    r"Q:\s*(.+?)(?:\n|\r\n?)A:\s*(.+?)(?=\nQ:|\Z)",
                    re.DOTALL | re.IGNORECASE,
                )

                for match in qa_pattern.finditer(output_text):
                    question = match.group(1).strip()
                    answer = match.group(2).strip()
                    if question and answer and len(question) > 5 and len(answer) > 5:
                        qa_pairs.append({
                            "context": context,
                            "question": question,
                            "answer": answer,
                        })

            except Exception as e:
                logger.warning("API Q&A generation failed for doc %d: %s", doc_idx, e)

            if progress_callback:
                pct = 0.10 + ((doc_idx + 1) / len(doc_texts)) * 0.25
                progress_callback(min(pct, 0.35), f"Generating Q&A pairs ({doc_idx + 1}/{len(doc_texts)})")

    return qa_pairs


# ── Context compression ──────────────────────────────────────────


def _compress_context(text: str, compression_ratio: float) -> str:
    """Compress a document context using CLaRa embeddings.

    Creates a compressed representation by:
      1. Splitting text into sentences
      2. Encoding each sentence
      3. Selecting the top sentences by importance (measured by vector magnitude
         diversity) to hit the target compression ratio
    """
    import re

    sentences = [s.strip() for s in re.split(r"[.!?]+", text) if len(s.strip()) > 10]
    if not sentences:
        return text

    # Number of sentences to keep
    target_count = max(1, int(len(sentences) * compression_ratio))

    if target_count >= len(sentences):
        return text

    # Encode sentences
    vectors = encode_texts(sentences)

    # Score each sentence by its L2 norm (information density proxy)
    # and by diversity (distance from mean)
    mean_vec = vectors.mean(axis=0)
    diversity_scores = np.linalg.norm(vectors - mean_vec, axis=1)
    magnitude_scores = np.linalg.norm(vectors, axis=1)

    # Combined score: balance information density and diversity
    combined_scores = 0.6 * magnitude_scores + 0.4 * diversity_scores

    # Select top sentences, preserving original order
    top_indices = np.argsort(-combined_scores)[:target_count]
    top_indices_sorted = sorted(top_indices)

    compressed = ". ".join(sentences[i] for i in top_indices_sorted) + "."
    return compressed


# ── Core distiller class ─────────────────────────────────────────


class ContextDistiller:
    """Context distillation: teaches a model to reason over compressed context.

    Pipeline:
      1. Generate Q&A pairs using the model with full context
      2. Compress the context using CLaRa
      3. Train the model (LoRA) to answer questions from compressed context
    """

    def __init__(self) -> None:
        pass

    async def distill_context(
        self,
        model_id: str,
        documents: list[dict[str, Any]],
        config: dict[str, Any],
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> ContextDistillResult:
        """Run the full context distillation pipeline.

        Parameters
        ----------
        model_id:
            ID of the model to train (will be LoRA-adapted).
        documents:
            List of dicts with at least ``"text"`` (str) and optionally ``"doc_id"``.
        config:
            Config dict (see ContextDistillConfig schema).
        progress_callback:
            Optional ``(progress_0_to_1, status_message) -> None``.
        """
        num_qa_per_doc = config.get("num_qa_pairs_per_doc", 10)
        compression_ratio = config.get("compression_ratio", 0.3)
        learning_rate = config.get("learning_rate", 1e-4)
        epochs = config.get("epochs", 3)
        batch_size = config.get("batch_size", 4)
        max_seq_length = config.get("max_seq_length", 512)
        lora_rank = config.get("lora_rank", 8)
        lora_alpha_param = config.get("lora_alpha", 16)

        if not documents:
            return ContextDistillResult(success=False, error="No documents provided")

        # Check dependencies
        if not (_HAS_TORCH and _HAS_TRANSFORMERS and _HAS_PEFT):
            missing = []
            if not _HAS_TORCH:
                missing.append("torch")
            if not _HAS_TRANSFORMERS:
                missing.append("transformers")
            if not _HAS_PEFT:
                missing.append("peft")
            return ContextDistillResult(
                success=False,
                error=f"Missing required dependencies: {', '.join(missing)}",
            )

        if progress_callback:
            progress_callback(0.05, "Resolving model")

        model_path = _find_model_path(model_id)

        # ── Step 1: Generate Q&A pairs with full context ──
        doc_texts = [d.get("text", "") for d in documents if d.get("text")]
        if not doc_texts:
            return ContextDistillResult(success=False, error="No document texts found")

        if progress_callback:
            progress_callback(0.08, "Generating Q&A pairs from full context")

        if model_path is not None:
            qa_pairs = await _generate_qa_pairs_local(
                model_path=model_path,
                doc_texts=doc_texts,
                num_pairs_per_doc=num_qa_per_doc,
                progress_callback=progress_callback,
            )
        else:
            # Try via inference API
            qa_pairs = await _generate_qa_pairs_api(
                doc_texts=doc_texts,
                num_pairs_per_doc=num_qa_per_doc,
                progress_callback=progress_callback,
            )

        if not qa_pairs:
            return ContextDistillResult(
                success=False,
                error="Failed to generate Q&A pairs. Ensure a model is loaded.",
            )

        logger.info("Generated %d Q&A pairs from %d documents", len(qa_pairs), len(doc_texts))

        if progress_callback:
            progress_callback(0.40, "Compressing contexts with CLaRa")

        # ── Step 2: Compress context for each Q&A pair ──
        compressed_qa: list[dict[str, str]] = []
        for idx, qa in enumerate(qa_pairs):
            compressed_ctx = _compress_context(qa["context"], compression_ratio)
            compressed_qa.append({
                "compressed_context": compressed_ctx,
                "question": qa["question"],
                "answer": qa["answer"],
                "original_context": qa["context"],
            })

            if progress_callback and idx % 20 == 0:
                pct = 0.40 + (idx / len(qa_pairs)) * 0.10
                progress_callback(min(pct, 0.50), f"Compressing contexts ({idx + 1}/{len(qa_pairs)})")

        if progress_callback:
            progress_callback(0.50, "Starting LoRA fine-tuning on compressed context")

        # ── Step 3: Train model to answer from compressed context via LoRA ──
        if model_path is None:
            return ContextDistillResult(
                success=False,
                error=f"Model '{model_id}' not found for LoRA training. "
                f"Context distillation requires a local transformers model.",
            )

        adapter_dir = ADAPTERS_DIR / f"ctx-distill-{model_id}-{int(time.time())}"

        result = await self._train_on_compressed(
            model_path=model_path,
            model_id=model_id,
            compressed_qa=compressed_qa,
            adapter_dir=adapter_dir,
            learning_rate=learning_rate,
            epochs=epochs,
            batch_size=batch_size,
            max_seq_length=max_seq_length,
            lora_rank=lora_rank,
            lora_alpha_param=lora_alpha_param,
            progress_callback=progress_callback,
        )

        result.num_documents = len(doc_texts)
        result.num_qa_pairs = len(compressed_qa)

        return result

    async def _train_on_compressed(
        self,
        model_path: Path,
        model_id: str,
        compressed_qa: list[dict[str, str]],
        adapter_dir: Path,
        learning_rate: float,
        epochs: int,
        batch_size: int,
        max_seq_length: int,
        lora_rank: int,
        lora_alpha_param: int,
        progress_callback: Callable[[float, str], None] | None = None,
    ) -> ContextDistillResult:
        """Fine-tune the model to answer questions from compressed context."""

        def _blocking_train() -> ContextDistillResult:
            import torch.nn as nn

            device = _select_device()
            dtype = _get_dtype(device)
            start_time = time.time()

            # ── 1. Load tokenizer ──
            try:
                tokenizer = AutoTokenizer.from_pretrained(str(model_path), trust_remote_code=True)
            except Exception:
                tokenizer = AutoTokenizer.from_pretrained(str(model_path), trust_remote_code=True, use_fast=False)

            if tokenizer.pad_token is None:
                tokenizer.pad_token = tokenizer.eos_token

            # ── 2. Load model + LoRA ──
            load_kwargs: dict[str, Any] = {
                "trust_remote_code": True,
                "low_cpu_mem_usage": True,
                "torch_dtype": dtype if device == "cuda" else torch.float32,
            }
            if device == "cuda":
                load_kwargs["device_map"] = "auto"

            try:
                model = AutoModelForCausalLM.from_pretrained(str(model_path), **load_kwargs)
            except Exception as e:
                return ContextDistillResult(success=False, error=f"Failed to load model: {e}")

            if device != "cuda":
                try:
                    model = model.to(device)
                except Exception:
                    model = model.to("cpu")
                    device = "cpu"

            # Determine target modules
            config_file = model_path / "config.json"
            model_type = ""
            if config_file.exists():
                with open(config_file) as f:
                    model_type = json.load(f).get("model_type", "")

            target_modules = _infer_target_modules(model_type)

            # Validate target modules
            all_module_names = {name for name, _ in model.named_modules()}
            valid_targets = [
                t for t in target_modules
                if any(n.endswith(f".{t}") or n == t for n in all_module_names)
            ]
            if not valid_targets:
                linear_names = set()
                for name, module in model.named_modules():
                    if isinstance(module, nn.Linear):
                        linear_names.add(name.split(".")[-1])
                valid_targets = list(linear_names)[:4]

            if not valid_targets:
                return ContextDistillResult(
                    success=False,
                    error="No suitable LoRA target modules found",
                )

            lora_config = LoraConfig(
                task_type=TaskType.CAUSAL_LM,
                r=lora_rank,
                lora_alpha=lora_alpha_param,
                lora_dropout=0.05,
                target_modules=valid_targets,
                bias="none",
            )
            model = get_peft_model(model, lora_config)
            model.train()

            trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
            logger.info("Context distillation LoRA: %d trainable params", trainable_params)

            # ── 3. Prepare training data ──
            # Format: instruction to answer from compressed context
            encodings = []
            for qa in compressed_qa:
                prompt = (
                    f"### Context (compressed):\n{qa['compressed_context']}\n\n"
                    f"### Question:\n{qa['question']}\n\n"
                    f"### Answer:\n{qa['answer']}"
                )

                enc = tokenizer(
                    prompt,
                    truncation=True,
                    max_length=max_seq_length,
                    padding="max_length",
                    return_tensors="pt",
                )
                encodings.append(enc)

            if not encodings:
                return ContextDistillResult(success=False, error="No valid training samples")

            # ── 4. Training loop ──
            optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate, weight_decay=0.01)
            step_losses: list[float] = []
            total_steps = 0

            for epoch in range(epochs):
                rng = np.random.default_rng(seed=epoch)
                indices = rng.permutation(len(encodings))
                epoch_loss = 0.0
                num_batches = 0

                for batch_start in range(0, len(indices), batch_size):
                    batch_idx = indices[batch_start : batch_start + batch_size]

                    batch_loss_sum = 0.0
                    for i in batch_idx:
                        enc = encodings[i]
                        input_ids = enc["input_ids"].to(device)
                        attention_mask = enc["attention_mask"].to(device)
                        labels = input_ids.clone()
                        labels[labels == tokenizer.pad_token_id] = -100

                        try:
                            outputs = model(
                                input_ids=input_ids,
                                attention_mask=attention_mask,
                                labels=labels,
                            )
                            loss = outputs.loss
                        except RuntimeError as e:
                            if "out of memory" in str(e).lower():
                                logger.error("OOM during context distillation")
                                if device == "cuda":
                                    torch.cuda.empty_cache()
                                raise
                            raise

                        loss.backward()
                        batch_loss_sum += loss.item()

                    # Average gradient over batch items
                    if len(batch_idx) > 1:
                        for param in model.parameters():
                            if param.grad is not None:
                                param.grad /= len(batch_idx)

                    torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
                    optimizer.step()
                    optimizer.zero_grad()

                    avg_batch_loss = batch_loss_sum / len(batch_idx)
                    step_losses.append(avg_batch_loss)
                    epoch_loss += avg_batch_loss
                    num_batches += 1
                    total_steps += 1

                avg_epoch_loss = epoch_loss / max(num_batches, 1)
                logger.info("Epoch %d/%d — avg_loss: %.6f", epoch + 1, epochs, avg_epoch_loss)

                if progress_callback:
                    pct = 0.50 + ((epoch + 1) / epochs) * 0.35
                    progress_callback(min(pct, 0.85), f"Training epoch {epoch + 1}/{epochs}")

            # ── 5. Save adapter ──
            adapter_dir.mkdir(parents=True, exist_ok=True)
            model.save_pretrained(str(adapter_dir))

            # Save context distillation config
            distill_config = {
                "studiomc_format": "context_distilled_lora",
                "model_id": model_id,
                "compression_ratio": compressed_qa[0].get("compression_ratio", 0.3) if compressed_qa else 0.3,
                "num_qa_pairs": len(compressed_qa),
                "lora_rank": lora_rank,
                "lora_alpha": lora_alpha_param,
                "target_modules": valid_targets,
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
                    existing = json.load(f)
                existing.update(distill_config)
                distill_config = existing
            config_path.write_text(json.dumps(distill_config, indent=2))

            # Also save the Q&A pairs for reference
            qa_path = adapter_dir / "context_distill_qa.jsonl"
            lines = [json.dumps(qa, ensure_ascii=False) for qa in compressed_qa]
            qa_path.write_text("\n".join(lines), encoding="utf-8")

            elapsed = time.time() - start_time

            # Cleanup
            del model, optimizer
            if device == "cuda":
                torch.cuda.empty_cache()

            return ContextDistillResult(
                success=True,
                adapter_dir=str(adapter_dir),
                epochs_completed=epochs,
                final_loss=step_losses[-1] if step_losses else None,
                metrics={
                    "method": "context_distillation",
                    "num_qa_pairs": len(compressed_qa),
                    "total_steps": total_steps,
                    "final_loss": step_losses[-1] if step_losses else None,
                    "avg_loss": sum(step_losses) / len(step_losses) if step_losses else None,
                    "trainable_params": trainable_params,
                    "device": device,
                    "elapsed_seconds": round(elapsed, 1),
                    "step_losses_last10": step_losses[-10:],
                },
            )

        return await asyncio.to_thread(_blocking_train)


# ── Module-level singleton ───────────────────────────────────────

_distiller_instance: ContextDistiller | None = None


def get_context_distiller() -> ContextDistiller:
    """Return a singleton ContextDistiller."""
    global _distiller_instance
    if _distiller_instance is None:
        _distiller_instance = ContextDistiller()
    return _distiller_instance
