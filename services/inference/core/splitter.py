"""Model splitter — splits HuggingFace models into per-layer safetensors files.

Takes a model directory containing sharded safetensors files and splits them
into individual per-layer files for out-of-core inference. Each layer gets
its own .safetensors file that can be loaded independently.

Based on the out-of-core inference approach: instead of loading the entire
model, we split it so each layer can be streamed from disk independently.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
from collections import defaultdict
from pathlib import Path
from typing import Any

import torch
from safetensors.torch import load_file, save_file

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

    Returns:
        Dict of layer_name -> {weight_name: shard_filename}
    """
    groups: dict[str, dict[str, str]] = defaultdict(dict)

    if weight_map is not None:
        # Sharded model: use the index
        for weight_name, shard_file in weight_map.items():
            layer = _classify_weight(weight_name)
            groups[layer][weight_name] = shard_file
    else:
        # Single-file model: load metadata to get weight names
        from safetensors import safe_open

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


async def split_model(
    model_path: str,
    output_path: str | None = None,
    delete_original: bool = False,
) -> list[str]:
    """Split a model into per-layer safetensors files.

    Reads the model's weight index (or single safetensors file) and creates
    individual .safetensors files for each logical layer (embed_tokens,
    layers.0 through layers.N, norm, lm_head).

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

    logger.info("Splitting model from %s to %s", src, dst)

    loop = asyncio.get_event_loop()

    # Read weight index
    weight_map = await loop.run_in_executor(None, _read_weight_index, src)

    # Group weights by layer
    groups = await loop.run_in_executor(
        None, _group_weights_by_layer, weight_map, src
    )

    layer_names = _sort_layer_names(list(groups.keys()))
    logger.info("Found %d layers to split: %s", len(layer_names), layer_names)

    # Cache loaded shard files to avoid re-reading
    shard_cache: dict[str, dict[str, torch.Tensor]] = {}

    def _load_shard(filename: str) -> dict[str, torch.Tensor]:
        if filename not in shard_cache:
            shard_path = str(src / filename)
            logger.debug("Loading shard: %s", filename)
            shard_cache[filename] = load_file(shard_path)
        return shard_cache[filename]

    def _save_layer(layer_name: str, weight_names: dict[str, str]) -> None:
        """Extract and save weights for a single layer."""
        layer_tensors: dict[str, torch.Tensor] = {}

        # Collect all shards we need for this layer
        needed_shards: set[str] = set(weight_names.values())
        for shard_file in needed_shards:
            _load_shard(shard_file)

        # Extract the specific tensors for this layer
        for weight_name, shard_file in weight_names.items():
            shard_data = shard_cache[shard_file]
            if weight_name in shard_data:
                layer_tensors[weight_name] = shard_data[weight_name]
            else:
                logger.warning(
                    "Weight %s not found in shard %s", weight_name, shard_file
                )

        if not layer_tensors:
            logger.warning("No tensors found for layer %s, skipping", layer_name)
            return

        # Save the layer
        out_file = dst / f"{layer_name}.safetensors"
        save_file(layer_tensors, str(out_file))

        # Write done marker
        marker = dst / f"{layer_name}{_DONE_SUFFIX}"
        marker.touch()

        logger.info(
            "Saved layer %s (%d tensors, %.1f MB)",
            layer_name,
            len(layer_tensors),
            out_file.stat().st_size / (1024 * 1024),
        )

    # Split each layer (run in executor to avoid blocking)
    for layer_name in layer_names:
        await loop.run_in_executor(
            None, _save_layer, layer_name, groups[layer_name]
        )

        # Free shard cache periodically to manage memory
        # Keep only shards needed by remaining layers
        remaining_shards: set[str] = set()
        for future_layer in layer_names[layer_names.index(layer_name) + 1 :]:
            remaining_shards.update(groups[future_layer].values())
        for cached_shard in list(shard_cache.keys()):
            if cached_shard not in remaining_shards:
                del shard_cache[cached_shard]

    # Write the layer manifest
    manifest_path = dst / "layer_names.json"
    with open(manifest_path, "w") as f:
        json.dump(layer_names, f, indent=2)

    # Copy config files to output if different from source
    if dst != src:
        for config_file in ("config.json", "tokenizer.json", "tokenizer_config.json",
                            "special_tokens_map.json", "generation_config.json"):
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
