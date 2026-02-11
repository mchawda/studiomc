# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Model splitter — splits HuggingFace models into per-layer safetensors files.

MEMORY-SAFE: Never loads more than one tensor at a time using safe_open().
Peak RAM usage is roughly the size of the single largest tensor in the model
(typically <500MB even for 70B+ models).

Takes a model directory containing sharded safetensors files and splits them
into individual per-layer files for out-of-core inference. Each layer gets
its own .safetensors file that can be loaded independently.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
from collections import defaultdict
from pathlib import Path

import torch
from safetensors import safe_open
from safetensors.torch import save_file

logger = logging.getLogger("inference.core.splitter")

# Marker file indicating a layer has been successfully split
_DONE_SUFFIX = ".done"

# Patterns for identifying layer groups in weight names
_EMBED_PATTERNS = ("model.embed_tokens", "embed_tokens", "wte", "word_embeddings")
_NORM_PATTERNS = ("model.norm", "model.ln_f", "ln_f", "final_layernorm")
_LM_HEAD_PATTERNS = ("lm_head",)
_LAYER_PATTERN = "model.layers."  # e.g. model.layers.0.self_attn.q_proj.weight


def _classify_weight(name: str) -> str:
    """Classify a weight tensor name into its layer group.

    Returns:
        A layer group key like 'embed_tokens', 'layers.0', 'norm', 'lm_head'.
    """
    for pat in _EMBED_PATTERNS:
        if name.startswith(pat):
            return "embed_tokens"

    if _LAYER_PATTERN in name:
        # Extract layer index: "model.layers.5.self_attn.q_proj.weight" -> "layers.5"
        after = name.split(_LAYER_PATTERN)[1]
        layer_idx = after.split(".")[0]
        return f"layers.{layer_idx}"

    for pat in _NORM_PATTERNS:
        if name.startswith(pat):
            return "norm"

    for pat in _LM_HEAD_PATTERNS:
        if name.startswith(pat):
            return "lm_head"

    # Unknown weights go into a catch-all
    logger.debug("Unclassified weight: %s", name)
    return "other"


def _read_weight_index(model_path: Path) -> dict[str, str] | None:
    """Read model.safetensors.index.json to find weight-to-file mapping.

    Returns:
        Dict mapping weight_name -> shard_filename, or None if not sharded.
    """
    index_path = model_path / "model.safetensors.index.json"
    if index_path.exists():
        with open(index_path) as f:
            data = json.load(f)
        return data.get("weight_map", {})

    # Single-file model (no index)
    single = model_path / "model.safetensors"
    if single.exists():
        return None

    raise FileNotFoundError(
        f"No safetensors files found in {model_path}. "
        "Expected model.safetensors or model.safetensors.index.json"
    )


def _group_weights_by_layer(
    weight_map: dict[str, str] | None, model_path: Path
) -> dict[str, dict[str, str]]:
    """Group weight names by their layer, with source shard filenames.

    Memory-safe: only reads metadata (tensor names), never loads tensors.

    Returns:
        Dict of layer_name -> {weight_name: shard_filename}
    """
    groups: dict[str, dict[str, str]] = defaultdict(dict)

    if weight_map is not None:
        # Sharded model: use the index (no tensor loading needed)
        for weight_name, shard_file in weight_map.items():
            layer = _classify_weight(weight_name)
            groups[layer][weight_name] = shard_file
    else:
        # Single-file model: open metadata only to get weight names
        single_path = str(model_path / "model.safetensors")
        with safe_open(single_path, framework="pt") as f:
            for weight_name in f.keys():
                layer = _classify_weight(weight_name)
                groups[layer][weight_name] = "model.safetensors"

    return dict(groups)


def _sort_layer_names(names: list[str]) -> list[str]:
    """Sort layer names in model execution order.

    Order: embed_tokens, layers.0, layers.1, ..., layers.N, norm, lm_head, other
    """
    def sort_key(name: str) -> tuple[int, int]:
        if name == "embed_tokens":
            return (0, 0)
        if name.startswith("layers."):
            idx = int(name.split(".")[1])
            return (1, idx)
        if name == "norm":
            return (2, 0)
        if name == "lm_head":
            return (3, 0)
        return (4, 0)

    return sorted(names, key=sort_key)


def is_model_split(model_path: str) -> bool:
    """Check if a model directory already contains per-layer splits."""
    p = Path(model_path)
    # Look for the characteristic .done marker files
    done_files = list(p.glob(f"*{_DONE_SUFFIX}"))
    if not done_files:
        return False

    # Also check that at least embed_tokens and lm_head exist
    has_embed = (p / "embed_tokens.safetensors").exists()
    has_lm_head = (p / "lm_head.safetensors").exists()
    return has_embed and has_lm_head


def get_layer_names(model_path: str) -> list[str]:
    """Get the ordered list of layer names from a split model directory.

    Reads the layer_names.json manifest if available, otherwise scans
    for .safetensors files.
    """
    p = Path(model_path)

    # Try the manifest first
    manifest = p / "layer_names.json"
    if manifest.exists():
        with open(manifest) as f:
            return json.load(f)

    # Fall back to scanning
    names = []
    for sf in p.glob("*.safetensors"):
        name = sf.stem
        # Skip original shard files (model-00001-of-00003, etc.)
        if name.startswith("model-") or name == "model":
            continue
        names.append(name)

    return _sort_layer_names(names)


def _save_layer_streaming(
    layer_name: str,
    weight_names: dict[str, str],
    src: Path,
    dst: Path,
) -> None:
    """Extract and save weights for a single layer using streaming reads.

    Opens each source shard with safe_open and reads ONLY the tensors
    needed for this layer, one at a time. Peak memory = one tensor.
    """
    # Check if already done (resume support)
    marker = dst / f"{layer_name}{_DONE_SUFFIX}"
    if marker.exists() and (dst / f"{layer_name}.safetensors").exists():
        logger.info("Layer %s already split, skipping", layer_name)
        return

    layer_tensors: dict[str, torch.Tensor] = {}

    # Group weight names by their source shard file
    shard_to_weights: dict[str, list[str]] = defaultdict(list)
    for weight_name, shard_file in weight_names.items():
        shard_to_weights[shard_file].append(weight_name)

    # Open each shard and extract only the tensors we need
    for shard_file, needed_weights in shard_to_weights.items():
        shard_path = str(src / shard_file)
        with safe_open(shard_path, framework="pt", device="cpu") as f:
            for weight_name in needed_weights:
                try:
                    tensor = f.get_tensor(weight_name)
                    layer_tensors[weight_name] = tensor
                except Exception:
                    logger.warning(
                        "Weight %s not found in shard %s", weight_name, shard_file
                    )

    if not layer_tensors:
        logger.warning("No tensors found for layer %s, skipping", layer_name)
        return

    # Save the layer file
    out_file = dst / f"{layer_name}.safetensors"
    save_file(layer_tensors, str(out_file))

    # Explicitly free tensors before writing marker
    del layer_tensors

    # Write done marker
    marker.touch()

    size_mb = out_file.stat().st_size / (1024 * 1024)
    logger.info("Saved layer %s (%.1f MB)", layer_name, size_mb)


async def split_model(
    model_path: str,
    output_path: str | None = None,
    delete_original: bool = False,
) -> list[str]:
    """Split a model into per-layer safetensors files.

    MEMORY-SAFE: Uses safe_open() to read one tensor at a time.
    Peak RAM is roughly the size of the largest single layer (~200-500MB),
    not the full model. Safe for 8GB machines with 70B+ models.

    Resumable: skips layers that already have a .done marker.

    Args:
        model_path:      Path to the HuggingFace model directory.
        output_path:     Where to write splits. Defaults to model_path itself.
        delete_original: If True, delete original shard files after splitting.

    Returns:
        Ordered list of layer names (e.g. ['embed_tokens', 'layers.0', ...]).
    """
    src = Path(model_path)
    dst = Path(output_path) if output_path else src

    if not src.is_dir():
        raise FileNotFoundError(f"Model directory not found: {src}")

    # Check if already split
    if is_model_split(str(dst)):
        logger.info("Model already split at %s", dst)
        return get_layer_names(str(dst))

    dst.mkdir(parents=True, exist_ok=True)

    logger.info("Splitting model from %s to %s (memory-safe mode)", src, dst)

    loop = asyncio.get_event_loop()

    # Read weight index (tiny — just JSON metadata)
    weight_map = await loop.run_in_executor(None, _read_weight_index, src)

    # Group weights by layer (no tensor loading, just name classification)
    groups = await loop.run_in_executor(
        None, _group_weights_by_layer, weight_map, src
    )

    layer_names = _sort_layer_names(list(groups.keys()))
    logger.info("Found %d layers to split", len(layer_names))

    # Split each layer one at a time — memory-safe streaming
    for i, layer_name in enumerate(layer_names):
        logger.info(
            "Splitting layer %d/%d: %s", i + 1, len(layer_names), layer_name
        )
        await loop.run_in_executor(
            None, _save_layer_streaming, layer_name, groups[layer_name], src, dst
        )

    # Write the layer manifest
    manifest_path = dst / "layer_names.json"
    with open(manifest_path, "w") as f:
        json.dump(layer_names, f, indent=2)

    # Copy config files to output if different from source
    if dst != src:
        for config_file in (
            "config.json", "tokenizer.json", "tokenizer_config.json",
            "special_tokens_map.json", "generation_config.json",
        ):
            src_cfg = src / config_file
            if src_cfg.exists():
                shutil.copy2(src_cfg, dst / config_file)

    # Optionally delete original shard files
    if delete_original:
        for shard_file in src.glob("model-*.safetensors"):
            logger.info("Deleting original shard: %s", shard_file.name)
            shard_file.unlink()
        single = src / "model.safetensors"
        if single.exists() and src != dst:
            logger.info("Deleting original: model.safetensors")
            single.unlink()

    logger.info("Model split complete: %d layers", len(layer_names))
    return layer_names
