# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""PEFT LoRA adapter loader — hot-swap adapters on a base model.

Loads and unloads PEFT LoRA adapters on top of a loaded base model
without needing to reload the base weights. Compatible with adapters
produced by ``training.lora_trainer``.

Capabilities:
    - ``load_adapter(engine, adapter_path)`` — apply a LoRA adapter
    - ``unload_adapter(engine)`` — remove adapter, revert to base model
    - Validates adapter compatibility with the loaded base model
    - Supports hot-swapping: switch adapters without reloading the base
    - Tracks adapter state for the router / API layer
"""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path

logger = logging.getLogger("inference.core.adapter_loader")

# ── Optional dependency detection ─────────────────────────────────────

_HAS_PEFT = False
try:
    from peft import PeftModel, PeftConfig  # type: ignore[import-untyped]
    _HAS_PEFT = True
except ImportError:
    logger.info("peft not installed — adapter loading will be unavailable")

_HAS_TORCH = False
try:
    import torch
    _HAS_TORCH = True
except ImportError:
    pass


class AdapterLoader:
    """Manages PEFT LoRA adapter loading / unloading on a base model.

    Usage::

        loader = AdapterLoader()

        # After the engine has a model loaded:
        info = await loader.load_adapter(engine, "/path/to/adapter")
        print(info)  # {"adapter_path": ..., "format": "lora_peft", ...}

        # Hot-swap to a different adapter (no base reload):
        await loader.load_adapter(engine, "/path/to/other-adapter")

        # Revert to base model:
        await loader.unload_adapter(engine)
    """

    def __init__(self) -> None:
        self._active_adapter_path: str | None = None
        self._active_adapter_config: dict | None = None
        self._original_model: object | None = None  # reference to un-adapted model
        self._is_adapted = False

    @property
    def is_adapted(self) -> bool:
        """True if an adapter is currently active."""
        return self._is_adapted

    @property
    def active_adapter_path(self) -> str | None:
        return self._active_adapter_path

    # ── Validation ────────────────────────────────────────────────────

    @staticmethod
    def validate_adapter(adapter_path: str) -> tuple[bool, str, dict]:
        """Validate that an adapter directory is well-formed.

        Checks:
            - Directory exists
            - adapter_config.json is present and parseable
            - Required PEFT files exist (adapter_model.safetensors or .bin)

        Returns:
            (is_valid, message, config_dict)
        """
        p = Path(adapter_path)

        if not p.exists():
            return False, f"Adapter path does not exist: {adapter_path}", {}

        if not p.is_dir():
            return False, f"Not a directory: {adapter_path}", {}

        # Check for adapter_config.json
        config_path = p / "adapter_config.json"
        if not config_path.exists():
            return False, f"Missing adapter_config.json in {adapter_path}", {}

        try:
            with open(config_path) as f:
                config = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            return False, f"Cannot read adapter_config.json: {e}", {}

        # Determine adapter format
        adapter_format = config.get("studiomc_format", config.get("peft_type", "unknown"))

        if adapter_format == "prompt_injection":
            # Prompt-injection adapters don't need PEFT files
            return True, "Valid prompt-injection adapter", config

        # For PEFT adapters, check for weight files
        has_safetensors = (p / "adapter_model.safetensors").exists()
        has_bin = (p / "adapter_model.bin").exists()

        if not has_safetensors and not has_bin:
            return (
                False,
                f"No adapter weight files found in {adapter_path} "
                f"(expected adapter_model.safetensors or adapter_model.bin)",
                config,
            )

        return True, "Valid PEFT LoRA adapter", config

    @staticmethod
    def check_compatibility(
        adapter_config: dict,
        base_model_path: str | None,
    ) -> tuple[bool, str]:
        """Check if an adapter is compatible with the loaded base model.

        Compatibility checks:
            - base_model_name_or_path matches (if specified)
            - Model type matches (if both specify it)
        """
        if not base_model_path:
            return True, "No base model path to validate against"

        # Check base_model_name_or_path from PEFT config
        adapter_base = adapter_config.get("base_model_name_or_path", "")
        adapter_model_path = adapter_config.get("model_path", "")

        if adapter_base or adapter_model_path:
            # Normalize paths for comparison
            base_name = Path(base_model_path).name
            adapter_base_name = Path(adapter_base).name if adapter_base else ""
            adapter_path_name = Path(adapter_model_path).name if adapter_model_path else ""

            if base_name and (base_name == adapter_base_name or base_name == adapter_path_name):
                return True, "Base model name matches adapter config"

            # Soft warning — don't block, just warn
            logger.warning(
                "Adapter base model '%s' may not match loaded model '%s'",
                adapter_base or adapter_model_path,
                base_model_path,
            )

        return True, "Compatibility check passed (no strict mismatch detected)"

    # ── Loading ───────────────────────────────────────────────────────

    async def load_adapter(
        self,
        engine: object,
        adapter_path: str,
    ) -> dict:
        """Load a PEFT LoRA adapter onto the engine's base model.

        If an adapter is already active, it is unloaded first (hot-swap).
        For prompt-injection adapters, stores the config for use during
        generation (the adapter data is injected into prompts, not weights).

        Args:
            engine:       InferenceEngine instance with a loaded model.
            adapter_path: Path to the PEFT adapter directory.

        Returns:
            Dict with adapter info: path, format, base_model_id, etc.
        """
        from inference.engine import InferenceEngine

        if not isinstance(engine, InferenceEngine):
            raise TypeError("Expected InferenceEngine instance")

        if not engine.is_loaded:
            raise RuntimeError("No base model loaded — load a model first")

        # Validate adapter
        is_valid, msg, config = self.validate_adapter(adapter_path)
        if not is_valid:
            raise ValueError(f"Invalid adapter: {msg}")

        # Check compatibility
        base_path = engine.state.active_model_path
        is_compat, compat_msg = self.check_compatibility(config, base_path)
        if not is_compat:
            raise ValueError(f"Adapter incompatible: {compat_msg}")

        # Unload existing adapter first (hot-swap)
        if self._is_adapted:
            await self.unload_adapter(engine)

        adapter_format = config.get("studiomc_format", config.get("peft_type", "unknown"))

        if adapter_format == "prompt_injection":
            return await self._load_prompt_injection_adapter(config, adapter_path)

        if not _HAS_PEFT:
            raise RuntimeError(
                "peft library not installed. Install with: pip install peft"
            )

        return await self._load_peft_adapter(engine, adapter_path, config)

    async def _load_peft_adapter(
        self,
        engine: object,
        adapter_path: str,
        config: dict,
    ) -> dict:
        """Load a real PEFT LoRA adapter onto the engine's model."""
        from inference.engine import InferenceEngine

        if not isinstance(engine, InferenceEngine):
            raise TypeError("Expected InferenceEngine instance")

        ooc_engine = engine._engine  # OutOfCoreEngine

        if ooc_engine.model is None:
            raise RuntimeError("OutOfCoreEngine has no model loaded")

        loop = asyncio.get_event_loop()

        def _apply_adapter() -> dict:
            """Apply PEFT adapter (blocking, runs in thread pool)."""
            model = ooc_engine.model

            # Save reference to the original model for unloading
            # Note: PeftModel wraps the original, so we can unwrap later
            logger.info("Applying PEFT adapter from %s", adapter_path)

            try:
                adapted_model = PeftModel.from_pretrained(
                    model,
                    adapter_path,
                    is_trainable=False,
                )
                adapted_model.eval()

                # Replace the model in the engine
                ooc_engine.model = adapted_model

                logger.info(
                    "PEFT adapter applied: %s (rank=%s, target_modules=%s)",
                    adapter_path,
                    config.get("r", config.get("lora_rank", "?")),
                    config.get("target_modules", "?"),
                )

                return {
                    "adapter_path": adapter_path,
                    "format": "lora_peft",
                    "base_model_id": config.get("base_model_id", "unknown"),
                    "lora_rank": config.get("r", config.get("lora_rank")),
                    "target_modules": config.get("target_modules"),
                    "num_samples": config.get("num_samples"),
                }
            except Exception as e:
                logger.error("Failed to apply PEFT adapter: %s", e)
                raise

        info = await loop.run_in_executor(None, _apply_adapter)

        self._active_adapter_path = adapter_path
        self._active_adapter_config = config
        self._is_adapted = True

        return info

    async def _load_prompt_injection_adapter(
        self,
        config: dict,
        adapter_path: str,
    ) -> dict:
        """Load a prompt-injection adapter (no weight modification).

        The adapter's training samples are stored and will be injected
        into prompts at generation time by the engine.
        """
        logger.info(
            "Loaded prompt-injection adapter from %s (%d samples)",
            adapter_path,
            config.get("num_samples", 0),
        )

        self._active_adapter_path = adapter_path
        self._active_adapter_config = config
        self._is_adapted = True

        return {
            "adapter_path": adapter_path,
            "format": "prompt_injection",
            "base_model_id": config.get("base_model_id", "unknown"),
            "num_samples": config.get("num_samples", 0),
            "description": config.get("description", ""),
        }

    # ── Unloading ─────────────────────────────────────────────────────

    async def unload_adapter(self, engine: object) -> None:
        """Remove the active adapter, reverting to the base model.

        For PEFT adapters, this merges and unloads the adapter weights.
        For prompt-injection adapters, simply clears the stored config.
        """
        if not self._is_adapted:
            logger.debug("No adapter to unload")
            return

        from inference.engine import InferenceEngine

        adapter_format = "unknown"
        if self._active_adapter_config:
            adapter_format = self._active_adapter_config.get(
                "studiomc_format",
                self._active_adapter_config.get("peft_type", "unknown"),
            )

        if adapter_format != "prompt_injection" and _HAS_PEFT:
            if isinstance(engine, InferenceEngine):
                ooc_engine = engine._engine
                if ooc_engine.model is not None and isinstance(ooc_engine.model, PeftModel):
                    loop = asyncio.get_event_loop()

                    def _remove_adapter() -> None:
                        logger.info("Unloading PEFT adapter")
                        try:
                            # Get the base model back
                            base_model = ooc_engine.model.get_base_model()
                            ooc_engine.model = base_model
                            ooc_engine.model.eval()
                            logger.info("PEFT adapter removed, base model restored")
                        except Exception as e:
                            logger.error("Error removing PEFT adapter: %s", e)
                            raise

                    await loop.run_in_executor(None, _remove_adapter)

        # Clear state
        prev_path = self._active_adapter_path
        self._active_adapter_path = None
        self._active_adapter_config = None
        self._is_adapted = False

        logger.info("Adapter unloaded: %s", prev_path)

    # ── Status ────────────────────────────────────────────────────────

    def status(self) -> dict:
        """Return current adapter status."""
        result: dict = {
            "is_adapted": self._is_adapted,
            "adapter_path": self._active_adapter_path,
            "peft_available": _HAS_PEFT,
        }
        if self._active_adapter_config:
            result["adapter_format"] = self._active_adapter_config.get(
                "studiomc_format",
                self._active_adapter_config.get("peft_type", "unknown"),
            )
            result["base_model_id"] = self._active_adapter_config.get("base_model_id")
            result["lora_rank"] = self._active_adapter_config.get(
                "r", self._active_adapter_config.get("lora_rank")
            )
        return result
