# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Model Export — merge LoRA adapters and export to portable formats.

Supports:
  - GGUF export (for Ollama, llama.cpp, LM Studio)
  - Safetensors export (for HuggingFace, vLLM)
  - Push to HuggingFace Hub (optional, with user token)
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("training.export")


@dataclass
class ExportResult:
    """Outcome of a model export."""

    success: bool
    format: str  # "gguf", "safetensors", "huggingface"
    output_path: str
    size_bytes: int = 0
    error: str | None = None


async def merge_adapter(
    adapter_dir: Path,
    output_dir: Path,
) -> Path | None:
    """Merge a LoRA adapter into the base model.

    Reads adapter_config.json to find the base model path, loads both,
    merges, and saves the merged model to output_dir.
    """
    config_path = adapter_dir / "adapter_config.json"
    if not config_path.exists():
        logger.error("No adapter_config.json found in %s", adapter_dir)
        return None

    with open(config_path) as f:
        config = json.load(f)

    base_model_path = config.get("model_path") or config.get("base_model_name_or_path")
    adapter_format = config.get("studiomc_format", "")

    if not base_model_path:
        logger.error("No base model path in adapter config")
        return None

    output_dir.mkdir(parents=True, exist_ok=True)

    if adapter_format == "mlx_lora":
        return await _merge_mlx_adapter(
            Path(base_model_path), adapter_dir, output_dir
        )
    else:
        return await _merge_peft_adapter(
            Path(base_model_path), adapter_dir, output_dir
        )


async def _merge_peft_adapter(
    base_model_path: Path,
    adapter_dir: Path,
    output_dir: Path,
) -> Path | None:
    """Merge a PEFT LoRA adapter using transformers."""

    def _blocking_merge() -> Path | None:
        try:
            from peft import PeftModel
            from transformers import AutoModelForCausalLM, AutoTokenizer

            model = AutoModelForCausalLM.from_pretrained(
                str(base_model_path),
                trust_remote_code=True,
                low_cpu_mem_usage=True,
            )
            model = PeftModel.from_pretrained(model, str(adapter_dir))
            merged = model.merge_and_unload()

            merged.save_pretrained(str(output_dir))

            tokenizer = AutoTokenizer.from_pretrained(
                str(base_model_path), trust_remote_code=True
            )
            tokenizer.save_pretrained(str(output_dir))

            logger.info("Merged PEFT adapter to %s", output_dir)
            return output_dir

        except ImportError:
            logger.error("peft/transformers not installed for merge")
            return None
        except Exception as e:
            logger.exception("PEFT merge failed: %s", e)
            return None

    return await asyncio.to_thread(_blocking_merge)


async def _merge_mlx_adapter(
    base_model_path: Path,
    adapter_dir: Path,
    output_dir: Path,
) -> Path | None:
    """Merge an MLX LoRA adapter using mlx-lm."""

    def _blocking_merge() -> Path | None:
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "mlx_lm.fuse",
                    "--model",
                    str(base_model_path),
                    "--adapter-path",
                    str(adapter_dir),
                    "--save-path",
                    str(output_dir),
                ],
                capture_output=True,
                text=True,
                timeout=600,
            )
            if result.returncode != 0:
                logger.error("mlx-lm fuse failed: %s", result.stderr[-500:])
                return None
            logger.info("Merged MLX adapter to %s", output_dir)
            return output_dir
        except Exception as e:
            logger.exception("MLX merge failed: %s", e)
            return None

    return await asyncio.to_thread(_blocking_merge)


async def export_to_gguf(
    merged_dir: Path,
    output_path: Path,
    quantization: str = "q4_k_m",
) -> ExportResult:
    """Convert a merged model to GGUF format.

    Uses llama.cpp's convert script if available.
    """

    def _blocking_convert() -> ExportResult:
        output_path.parent.mkdir(parents=True, exist_ok=True)

        # Try llama-cpp-python's convert
        try:
            convert_script = shutil.which("convert-hf-to-gguf.py") or shutil.which(
                "convert_hf_to_gguf"
            )

            if not convert_script:
                # Try the common paths
                for candidate in [
                    Path.home() / ".local" / "bin" / "convert-hf-to-gguf.py",
                    Path("/usr/local/bin/convert-hf-to-gguf.py"),
                ]:
                    if candidate.exists():
                        convert_script = str(candidate)
                        break

            if convert_script:
                result = subprocess.run(
                    [
                        sys.executable,
                        str(convert_script),
                        str(merged_dir),
                        "--outtype",
                        quantization,
                        "--outfile",
                        str(output_path),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=1800,
                )
                if result.returncode == 0:
                    size = output_path.stat().st_size if output_path.exists() else 0
                    return ExportResult(
                        success=True,
                        format="gguf",
                        output_path=str(output_path),
                        size_bytes=size,
                    )
                else:
                    return ExportResult(
                        success=False,
                        format="gguf",
                        output_path=str(output_path),
                        error=f"Conversion failed: {result.stderr[-300:]}",
                    )
            else:
                return ExportResult(
                    success=False,
                    format="gguf",
                    output_path=str(output_path),
                    error="GGUF conversion tool not found. Install llama.cpp or llama-cpp-python.",
                )

        except Exception as e:
            return ExportResult(
                success=False,
                format="gguf",
                output_path=str(output_path),
                error=str(e),
            )

    return await asyncio.to_thread(_blocking_convert)


async def export_to_safetensors(
    merged_dir: Path,
    output_dir: Path,
) -> ExportResult:
    """Export merged model as safetensors (just copy if already in that format)."""
    output_dir.mkdir(parents=True, exist_ok=True)

    has_safetensors = any(merged_dir.glob("*.safetensors"))
    if not has_safetensors:
        return ExportResult(
            success=False,
            format="safetensors",
            output_path=str(output_dir),
            error="Merged model does not contain safetensors files.",
        )

    def _blocking_copy() -> ExportResult:
        try:
            total_size = 0
            for f in merged_dir.iterdir():
                if f.suffix in (".safetensors", ".json", ".txt", ".model"):
                    dest = output_dir / f.name
                    shutil.copy2(f, dest)
                    total_size += dest.stat().st_size

            return ExportResult(
                success=True,
                format="safetensors",
                output_path=str(output_dir),
                size_bytes=total_size,
            )
        except Exception as e:
            return ExportResult(
                success=False,
                format="safetensors",
                output_path=str(output_dir),
                error=str(e),
            )

    return await asyncio.to_thread(_blocking_copy)


async def push_to_huggingface(
    model_dir: Path,
    repo_id: str,
    token: str,
    private: bool = True,
) -> ExportResult:
    """Push a model to HuggingFace Hub."""

    def _blocking_push() -> ExportResult:
        try:
            from huggingface_hub import HfApi

            api = HfApi(token=token)

            api.create_repo(repo_id, private=private, exist_ok=True)
            api.upload_folder(
                folder_path=str(model_dir),
                repo_id=repo_id,
                commit_message="Upload fine-tuned model from Studiomc",
            )

            return ExportResult(
                success=True,
                format="huggingface",
                output_path=f"https://huggingface.co/{repo_id}",
            )
        except Exception as e:
            return ExportResult(
                success=False,
                format="huggingface",
                output_path="",
                error=str(e),
            )

    return await asyncio.to_thread(_blocking_push)
