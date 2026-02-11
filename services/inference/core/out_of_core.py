# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""SpliceLLM — out-of-core inference engine.

Runs models of any size by streaming layers from disk through memory,
one layer at a time. Only a single transformer layer is resident in memory.

Workflow:
    1. Model config and tokenizer are loaded normally (small footprint).
    2. Model skeleton is created with empty weights (no memory).
    3. During forward pass, each layer's weights are loaded from disk,
       used for computation, then discarded before the next layer.
    4. Prefetching overlaps disk I/O with GPU/CPU computation.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import AsyncIterator

import torch
import torch.nn.functional as F
from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer

from inference.core.loader import LayerLoader
from inference.core.memory import clean_memory
from inference.core.splitter import get_layer_names, is_model_split, split_model

logger = logging.getLogger("inference.core.out_of_core")


def _detect_device() -> str:
    """Detect the best available compute device.

    Priority: CUDA > MPS (Apple Silicon GPU) > CPU.
    MPS gives significant speedup for matmuls during out-of-core inference.
    """
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        _patch_mps_unsupported_ops()
        return "mps"
    return "cpu"


_mps_patched = False


def _patch_mps_unsupported_ops() -> None:
    """Monkey-patch torch.histc to avoid MPS 'histogram_mps' error on Int.

    MPS doesn't implement histc for integer tensors. The grouped_mm MoE
    expert forward in transformers uses torch.histc to count tokens per
    expert. We round-trip through CPU for this tiny operation.
    """
    global _mps_patched
    if _mps_patched:
        return
    _mps_patched = True

    _original_histc = torch.Tensor.histc

    def _safe_histc(self: torch.Tensor, bins: int = 100, min: int = 0, max: int = 0) -> torch.Tensor:
        orig_device = self.device
        needs_cast = not self.is_floating_point()
        work = self.cpu().float() if needs_cast or orig_device.type == "mps" else self
        return _original_histc(work, bins, min, max).to(orig_device)

    torch.Tensor.histc = _safe_histc

    # Also patch the module-level torch.histc
    _original_torch_histc = torch.histc

    def _safe_torch_histc(input: torch.Tensor, bins: int = 100, min: int = 0, max: int = 0, *, out: torch.Tensor | None = None) -> torch.Tensor:
        orig_device = input.device
        # histc doesn't support Int on any device — cast to float
        needs_cast = not input.is_floating_point()
        work = input.cpu().float() if needs_cast or orig_device.type == "mps" else input
        result = _original_torch_histc(work, bins, min, max)
        return result.to(orig_device)

    torch.histc = _safe_torch_histc

    logger.info("Patched torch.histc for MPS compatibility (Int fallback to CPU)")


class OutOfCoreEngine:
    """SpliceLLM — out-of-core inference engine.

    Runs models of any size by streaming layers from disk through memory,
    one layer at a time.

    Usage::

        engine = OutOfCoreEngine()
        await engine.load_model("/path/to/model")
        async for token in engine.generate_stream("Hello, world!"):
            print(token, end="", flush=True)
        await engine.unload_model()
    """

    def __init__(self) -> None:
        self.config: AutoConfig | None = None
        self.model: AutoModelForCausalLM | None = None
        self.tokenizer: AutoTokenizer | None = None
        self.layer_names: list[str] = []
        self.loader: LayerLoader | None = None
        self._device = _detect_device()
        self._dtype = torch.bfloat16  # will be set from config
        self._model_path: str | None = None

    @property
    def device(self) -> str:
        """The compute device being used."""
        return self._device

    @property
    def is_loaded(self) -> bool:
        """True if a model skeleton is loaded and ready for inference."""
        return self.model is not None and len(self.layer_names) > 0

    # Map common Ollama tags to HuggingFace repo IDs for auto-download
    OLLAMA_TO_HF: dict[str, str] = {
        "gpt-oss:20b": "openai/gpt-oss-20b",
        "llama3.2:latest": "meta-llama/Llama-3.2-3B-Instruct",
        "llama3.2": "meta-llama/Llama-3.2-3B-Instruct",
        "llama3.1:8b": "meta-llama/Llama-3.1-8B-Instruct",
        "llama3.1:70b": "meta-llama/Llama-3.1-70B-Instruct",
        "qwen2.5:7b": "Qwen/Qwen2.5-7B-Instruct",
        "qwen2.5:72b": "Qwen/Qwen2.5-72B-Instruct",
        "mistral": "mistralai/Mistral-7B-Instruct-v0.3",
        "mixtral:8x7b": "mistralai/Mixtral-8x7B-Instruct-v0.1",
        "deepseek-r1:70b": "deepseek-ai/DeepSeek-R1",
    }

    async def _resolve_model_path(self, tag: str) -> str | None:
        """Resolve an Ollama tag or model name to a local directory path.

        Checks:
            1. OLLAMA_TO_HF mapping -> look for already-downloaded HF model
            2. Common local model directories
        """
        # Check if it's a known Ollama tag
        hf_repo = self.OLLAMA_TO_HF.get(tag)
        if hf_repo:
            # Derive directory name from HF repo (e.g. "openai/gpt-oss-20b" -> "gpt-oss-20b")
            dir_name = hf_repo.split("/")[-1]
        else:
            dir_name = tag.replace(":", "-").replace("/", "-")

        # Search common model locations
        candidates = [
            Path.home() / ".studiomc" / "models" / dir_name,
            Path("/Volumes/External Drive/dev/projects/Studiomc/models") / dir_name,
            Path.cwd().parent / "models" / dir_name,
        ]

        for candidate in candidates:
            if candidate.is_dir():
                # Verify it has safetensors files
                has_safetensors = (
                    (candidate / "model.safetensors").exists()
                    or (candidate / "model.safetensors.index.json").exists()
                    or any(candidate.glob("*.safetensors"))
                )
                if has_safetensors:
                    logger.info("Resolved '%s' -> %s", tag, candidate)
                    return str(candidate)

        logger.debug("Could not resolve model tag: %s", tag)
        return None

    async def load_model(self, model_path: str) -> None:
        """Load model config and prepare for out-of-core inference.

        Uses init_empty_weights() for zero-memory skeleton, then
        manually initializes rotary embedding buffers (inv_freq) so
        position embeddings compute correctly.

        If the model path is an Ollama tag (not a directory), attempts to
        resolve it to a HuggingFace repo and auto-download.

        If the model hasn't been split into per-layer files yet, this
        will run the splitter first.

        Args:
            model_path: Path to the HuggingFace model directory or Ollama tag.
        """
        from accelerate import init_empty_weights

        path = Path(model_path)
        if not path.is_dir():
            # Try resolving Ollama tag to HuggingFace repo
            resolved = await self._resolve_model_path(model_path)
            if resolved is not None:
                path = Path(resolved)
                model_path = resolved
            else:
                raise FileNotFoundError(
                    f"Model directory not found: {model_path}. "
                    f"Not a known Ollama tag either."
                )

        logger.info("Loading model config from %s", model_path)

        loop = asyncio.get_event_loop()

        # Step 1: Load config
        self.config = await loop.run_in_executor(
            None, lambda: AutoConfig.from_pretrained(model_path, trust_remote_code=True)
        )

        # Detect model dtype from config.
        # gpt-oss uses MXFP4 quantized weights that require BF16 inputs,
        # so default to bfloat16 if config doesn't specify.
        config_dtype = getattr(self.config, "torch_dtype", None)
        if config_dtype and isinstance(config_dtype, torch.dtype):
            self._dtype = config_dtype
        elif config_dtype and isinstance(config_dtype, str) and config_dtype != "None":
            self._dtype = getattr(torch, config_dtype, torch.bfloat16)
        else:
            self._dtype = torch.bfloat16
        logger.info("Model dtype: %s (device: %s)", self._dtype, self._device)

        # Step 2: Load tokenizer
        logger.info("Loading tokenizer...")
        self.tokenizer = await loop.run_in_executor(
            None, lambda: AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
        )

        # Step 3: Split model if needed
        if not is_model_split(model_path):
            logger.info("Model not yet split — splitting into per-layer files...")
            self.layer_names = await split_model(model_path)
        else:
            self.layer_names = get_layer_names(model_path)
            logger.info("Found %d pre-split layers", len(self.layer_names))

        # Step 4: Create empty model skeleton (zero memory via meta device)
        logger.info("Creating empty model skeleton...")
        with init_empty_weights():
            self.model = await loop.run_in_executor(
                None,
                lambda: AutoModelForCausalLM.from_config(
                    self.config, trust_remote_code=True
                ),
            )
        self.model.eval()
        self.model.tie_weights()

        # Step 4b: Initialize rotary embedding buffers on CPU in model dtype.
        # init_empty_weights() leaves buffers like inv_freq on meta device
        # which breaks rotary embedding computation.
        self._init_rotary_buffers()

        # Step 4c: Ensure all non-meta buffers are in model dtype to prevent
        # mixed-precision issues during forward pass.
        for name, buf in self.model.named_buffers():
            if buf.device != torch.device("meta") and buf.dtype != self._dtype:
                # Replace buffer with correct dtype version
                parts = name.split(".")
                parent = self.model
                for part in parts[:-1]:
                    parent = getattr(parent, part)
                parent.register_buffer(
                    parts[-1], buf.to(self._dtype), persistent=False
                )

        # Step 5: Initialize the layer loader
        self.loader = LayerLoader(
            model_path=model_path,
            device="cpu",  # Load to CPU first, then move to device
            prefetch=True,
        )

        self._model_path = model_path
        logger.info(
            "Model ready for out-of-core inference on %s (%d layers)",
            self._device,
            len(self.layer_names),
        )

    async def unload_model(self) -> None:
        """Free all model resources."""
        if self.loader is not None:
            self.loader.close()
            self.loader = None

        if self.model is not None:
            del self.model
            self.model = None

        self.config = None
        self.tokenizer = None
        self.layer_names = []
        self._model_path = None

        clean_memory()
        logger.info("Model unloaded")

    def _apply_layer_weights(
        self, layer_module: torch.nn.Module, weights: dict[str, torch.Tensor]
    ) -> None:
        """Load weight tensors into a module, moving them to the target device."""
        state_dict = layer_module.state_dict()
        for param_name in state_dict:
            # Find the matching weight in the loaded tensors
            for weight_name, tensor in weights.items():
                if weight_name.endswith(param_name) or param_name in weight_name:
                    device_tensor = tensor.to(self._device)
                    # Use split to navigate to the actual parameter
                    parts = param_name.split(".")
                    module = layer_module
                    for part in parts[:-1]:
                        module = getattr(module, part)
                    setattr(module, parts[-1], torch.nn.Parameter(device_tensor, requires_grad=False))
                    break

    def _init_rotary_buffers(self) -> None:
        """Initialize rotary embedding buffers (inv_freq) on CPU.

        After init_empty_weights(), all buffers live on 'meta' device.
        Rotary embeddings need real inv_freq values to compute cos/sin.
        This re-creates them on CPU with proper values — tiny memory cost.
        """
        if self.model is None or self.config is None:
            return

        import math

        # Find the rotary embedding module
        rotary_emb = getattr(self.model.model, "rotary_emb", None)
        if rotary_emb is None:
            return

        # Get head_dim from config (varies by architecture)
        head_dim = getattr(self.config, "head_dim", None)
        if head_dim is None:
            hidden_size = getattr(self.config, "hidden_size", 4096)
            num_heads = getattr(self.config, "num_attention_heads", 32)
            head_dim = hidden_size // num_heads

        rope_theta = getattr(self.config, "rope_theta", 10000.0)

        # Compute inv_freq: 1.0 / (theta ** (2i / dim))
        inv_freq = 1.0 / (
            rope_theta
            ** (torch.arange(0, head_dim, 2, dtype=torch.float32) / head_dim)
        )

        # Register as a buffer on the rotary_emb module
        if hasattr(rotary_emb, "inv_freq"):
            rotary_emb.inv_freq = inv_freq
        else:
            rotary_emb.register_buffer("inv_freq", inv_freq, persistent=False)

        logger.info(
            "Initialized rotary buffers: head_dim=%d, rope_theta=%.0f",
            head_dim, rope_theta,
        )

    @staticmethod
    def _dequantize_mxfp4(
        blocks: torch.Tensor, scales: torch.Tensor
    ) -> torch.Tensor:
        """Dequantize MXFP4 blocks + scales into a dense bfloat16 tensor.

        MXFP4 packs two E2M1 FP4 values per uint8 byte (nibble-packed):
            High nibble (bits 7-4): first value  [sign, exp(2), man(1)]
            Low nibble  (bits 3-0): second value [sign, exp(2), man(1)]

        Each block of 16 bytes = 32 FP4 values, sharing one E8M0 scale.

        Args:
            blocks: uint8 tensor of shape (..., num_blocks, 16)
            scales: uint8 tensor of shape (..., num_blocks)

        Returns:
            Dequantized bfloat16 tensor of shape (..., num_blocks * 32)
        """
        def _decode_nibble(nibble: torch.Tensor) -> torch.Tensor:
            """Decode a 4-bit E2M1 nibble to float32."""
            sign = ((nibble >> 3) & 1).to(torch.float32)
            exp = ((nibble >> 1) & 0x3).to(torch.float32)
            man = (nibble & 0x1).to(torch.float32)

            is_zero = (exp == 0) & (man == 0)
            is_subnorm = (exp == 0) & (man == 1)

            value = torch.where(
                is_zero,
                torch.zeros_like(exp),
                torch.where(
                    is_subnorm,
                    torch.full_like(exp, 0.5),
                    (2.0 ** (exp - 1)) * (1.0 + man * 0.5),
                ),
            )
            return value * (1 - 2 * sign)

        # Unpack two FP4 values per byte
        hi = (blocks >> 4) & 0xF  # high nibble
        lo = blocks & 0xF         # low nibble

        # Decode both nibbles
        val_hi = _decode_nibble(hi)  # (..., num_blocks, 16)
        val_lo = _decode_nibble(lo)  # (..., num_blocks, 16)

        # Interleave: [hi0, lo0, hi1, lo1, ...] -> (..., num_blocks, 32)
        shape = list(val_hi.shape)
        interleaved = torch.stack([val_hi, val_lo], dim=-1)  # (..., num_blocks, 16, 2)
        interleaved = interleaved.reshape(
            shape[:-1] + [shape[-1] * 2]
        )  # (..., num_blocks, 32)

        # Decode scale: E8M0 (biased exponent, bias=127)
        scale_float = (2.0 ** (scales.to(torch.float32) - 127.0)).unsqueeze(-1)

        # Apply scale per block
        result = interleaved * scale_float

        # Reshape: merge last two dims (num_blocks, 32) -> (num_blocks * 32)
        orig_shape = list(result.shape)
        new_shape = orig_shape[:-2] + [orig_shape[-2] * orig_shape[-1]]
        return result.reshape(new_shape).to(torch.bfloat16)

    def _load_weights_into_module(
        self, module: torch.nn.Module, weights: dict[str, torch.Tensor],
        module_prefix: str = "",
    ) -> None:
        """Load weights into a module, dequantizing MXFP4 blocks on the fly.

        For normal float tensors: cast to model dtype and load.
        For MXFP4 quantized tensors (_blocks + _scales): dequantize to dense
        bfloat16 and reconstruct the original parameter name.
        """
        # Build a state dict with module-relative keys
        local_state: dict[str, torch.Tensor] = {}

        # First pass: collect all weights, stripping prefix
        stripped: dict[str, torch.Tensor] = {}
        for full_name, tensor in weights.items():
            if module_prefix and full_name.startswith(module_prefix):
                local_name = full_name[len(module_prefix):]
            else:
                local_name = full_name
            stripped[local_name] = tensor

        # Second pass: dequantize MXFP4 pairs and add normal weights
        processed_mxfp4: set[str] = set()
        for local_name, tensor in stripped.items():
            if local_name.endswith("_blocks"):
                base_name = local_name[: -len("_blocks")]
                scales_name = base_name + "_scales"
                if scales_name in stripped and base_name not in processed_mxfp4:
                    blocks = stripped[local_name]
                    scales = stripped[scales_name]
                    dense = self._dequantize_mxfp4(blocks, scales)
                    # MXFP4 stores weights transposed: [experts, out, in] but
                    # the model expects [experts, in, out]. Transpose last 2 dims.
                    if dense.ndim >= 2:
                        dense = dense.transpose(-2, -1).contiguous()
                    local_state[base_name] = dense.to(device=self._device)
                    processed_mxfp4.add(base_name)
                    logger.debug(
                        "Dequantized MXFP4: %s -> %s", local_name, list(dense.shape)
                    )
                continue
            elif local_name.endswith("_scales"):
                # Handled above with _blocks
                continue

            # Normal tensor
            if tensor.is_floating_point():
                tensor = tensor.to(device=self._device, dtype=self._dtype)
            else:
                tensor = tensor.to(device=self._device)
            local_state[local_name] = tensor

        # Use assign=True to replace meta tensors
        missing, unexpected = module.load_state_dict(
            local_state, strict=False, assign=True
        )
        if missing:
            logger.debug("Missing keys in %s: %s", module_prefix, missing)
        if unexpected:
            logger.debug("Unexpected keys in %s: %s", module_prefix, unexpected)

    def _move_module_to_meta(self, module: torch.nn.Module) -> None:
        """Move all parameters of a module to the 'meta' device (frees memory)."""
        for param_name, _param in list(module.named_parameters(recurse=True)):
            parts = param_name.split(".")
            target = module
            for part in parts[:-1]:
                target = getattr(target, part)
            setattr(
                target,
                parts[-1],
                torch.nn.Parameter(
                    torch.empty(0, device="meta"), requires_grad=False
                ),
            )

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        """Run a single forward pass using layer-by-layer disk streaming.

        For each layer in sequence:
            1. Prefetch the next layer in a background thread
            2. Load current layer weights to the compute device
            3. Run forward pass through the layer
            4. Move layer weights to 'meta' device (frees memory)
            5. Clean memory

        Args:
            input_ids: Tokenized input tensor of shape (batch, seq_len).

        Returns:
            Logits tensor of shape (batch, seq_len, vocab_size).
        """
        if self.model is None or self.loader is None:
            raise RuntimeError("No model loaded. Call load_model() first.")

        model = self.model
        device = self._device

        # Move input to device
        input_ids = input_ids.to(device)

        # ── Embedding layer ──────────────────────────────────────────
        embed_weights = self.loader.load_layer("embed_tokens")
        self._load_weights_into_module(
            model.model.embed_tokens, embed_weights, "model.embed_tokens."
        )
        hidden_states = model.model.embed_tokens(input_ids).to(self._dtype)
        self._move_module_to_meta(model.model.embed_tokens)
        del embed_weights
        clean_memory()

        # ── Transformer layers ───────────────────────────────────────
        # Prepare position-related inputs
        seq_len = hidden_states.shape[1]
        position_ids = torch.arange(
            seq_len, dtype=torch.long, device=device
        ).unsqueeze(0)

        # Precompute rotary position embeddings if the model has them.
        # Models like gpt-oss and Llama pass (cos, sin) as position_embeddings.
        # Cast to model dtype to avoid BF16/FP32 matmul mismatches.
        position_embeddings = None
        rotary_emb = getattr(model.model, "rotary_emb", None)
        if rotary_emb is not None:
            with torch.no_grad():
                try:
                    pe = rotary_emb(hidden_states, position_ids)
                    # Cast tuple of (cos, sin) to model dtype
                    if isinstance(pe, tuple):
                        position_embeddings = tuple(
                            t.to(self._dtype) for t in pe
                        )
                    else:
                        position_embeddings = pe.to(self._dtype)
                except Exception:
                    logger.debug("rotary_emb call failed, trying with seq_len")
                    try:
                        pe = rotary_emb(hidden_states, seq_len=seq_len)
                        if isinstance(pe, tuple):
                            position_embeddings = tuple(
                                t.to(self._dtype) for t in pe
                            )
                        else:
                            position_embeddings = pe.to(self._dtype)
                    except Exception:
                        logger.debug("rotary_emb fallback also failed")

        for i, layer_name in enumerate(self.layer_names):
            if not layer_name.startswith("layers."):
                continue

            layer_idx = int(layer_name.split(".")[1])
            layer_module = model.model.layers[layer_idx]

            # Prefetch next layer
            next_layer_idx = i + 1
            if next_layer_idx < len(self.layer_names):
                next_name = self.layer_names[next_layer_idx]
                if self.loader.prefetch:
                    self.loader.prefetch_layer(next_name)

            # Load current layer weights
            layer_weights = self.loader.load_layer(layer_name)
            self._load_weights_into_module(
                layer_module, layer_weights,
                f"model.layers.{layer_idx}.",
            )

            # Forward through this layer — ensure hidden_states is in model dtype.
            # RMSNorm internally upcasts to float32 for precision, which can
            # break MXFP4 expert matmuls that require BF16 inputs.
            with torch.no_grad():
                kwargs = {"position_ids": position_ids}
                if position_embeddings is not None:
                    kwargs["position_embeddings"] = position_embeddings

                layer_output = layer_module(
                    hidden_states.to(self._dtype), **kwargs
                )
                # Layer output is typically a tuple; hidden_states is the first element
                if isinstance(layer_output, tuple):
                    hidden_states = layer_output[0]
                else:
                    hidden_states = layer_output

            # Free layer weights
            self._move_module_to_meta(layer_module)
            del layer_weights
            clean_memory()

        # ── Final norm ───────────────────────────────────────────────
        if "norm" in self.layer_names:
            norm_weights = self.loader.load_layer("norm")
            self._load_weights_into_module(
                model.model.norm, norm_weights, "model.norm."
            )
            hidden_states = model.model.norm(hidden_states)
            self._move_module_to_meta(model.model.norm)
            del norm_weights
            clean_memory()

        # ── LM head ─────────────────────────────────────────────────
        if "lm_head" in self.layer_names:
            lm_weights = self.loader.load_layer("lm_head")
            self._load_weights_into_module(
                model.lm_head, lm_weights, "lm_head."
            )
            logits = model.lm_head(hidden_states)
            self._move_module_to_meta(model.lm_head)
            del lm_weights
        else:
            # Some models tie lm_head to embed_tokens
            embed_weights = self.loader.load_layer("embed_tokens")
            self._load_weights_into_module(
                model.model.embed_tokens, embed_weights, "model.embed_tokens."
            )
            logits = F.linear(hidden_states, model.model.embed_tokens.weight)
            self._move_module_to_meta(model.model.embed_tokens)
            del embed_weights

        clean_memory()
        return logits

    def _sample_next_token(
        self,
        logits: torch.Tensor,
        temperature: float = 0.7,
        top_p: float = 0.9,
        repetition_penalty: float = 1.15,
        generated_ids: list[int] | None = None,
    ) -> int:
        """Sample the next token from logits using temperature and top-p.

        Args:
            logits:             Raw logits for the last position (vocab_size,).
            temperature:        Sampling temperature (lower = more deterministic).
            top_p:              Nucleus sampling threshold.
            repetition_penalty: Penalty for already-generated tokens.
            generated_ids:      Previously generated token ids for repetition penalty.

        Returns:
            The sampled token id.
        """
        # Apply repetition penalty
        if generated_ids and repetition_penalty != 1.0:
            for token_id in set(generated_ids):
                if logits[token_id] > 0:
                    logits[token_id] /= repetition_penalty
                else:
                    logits[token_id] *= repetition_penalty

        if temperature <= 0:
            # Greedy decoding
            return logits.argmax(dim=-1).item()

        # Temperature scaling
        logits = logits / temperature

        # Top-p (nucleus) sampling
        sorted_logits, sorted_indices = torch.sort(logits, descending=True)
        cumulative_probs = torch.cumsum(F.softmax(sorted_logits, dim=-1), dim=-1)

        # Remove tokens with cumulative probability above the threshold
        sorted_indices_to_remove = cumulative_probs > top_p
        # Shift so that the first token above threshold is kept
        sorted_indices_to_remove[..., 1:] = sorted_indices_to_remove[..., :-1].clone()
        sorted_indices_to_remove[..., 0] = False

        # Set removed tokens to -inf
        indices_to_remove = sorted_indices[sorted_indices_to_remove]
        logits[indices_to_remove] = float("-inf")

        # Sample
        probs = F.softmax(logits, dim=-1)
        next_token = torch.multinomial(probs, num_samples=1)
        return next_token.item()

    async def generate_stream(
        self,
        prompt: str,
        max_new_tokens: int = 512,
        temperature: float = 0.7,
        top_p: float = 0.9,
        repetition_penalty: float = 1.15,
    ) -> AsyncIterator[str]:
        """Generate tokens one at a time, yielding each as a string.

        Autoregressive generation loop:
            1. Tokenize the prompt
            2. Run forward pass to get logits
            3. Sample next token
            4. Decode and yield the token text
            5. Repeat until EOS or max_new_tokens

        Args:
            prompt:             The input text prompt.
            max_new_tokens:     Maximum number of tokens to generate.
            temperature:        Sampling temperature.
            top_p:              Nucleus sampling threshold.
            repetition_penalty: Penalty for repeated tokens.

        Yields:
            Individual token strings as they are generated.
        """
        if not self.is_loaded:
            raise RuntimeError("No model loaded. Call load_model() first.")

        tokenizer = self.tokenizer
        loop = asyncio.get_event_loop()

        # Tokenize
        input_ids = tokenizer.encode(prompt, return_tensors="pt")
        generated_ids = input_ids[0].tolist()

        eos_token_id = getattr(tokenizer, "eos_token_id", None)

        for _ in range(max_new_tokens):
            # Build input tensor from all generated ids so far
            input_tensor = torch.tensor([generated_ids])

            # Forward pass (run in executor to avoid blocking the event loop)
            logits = await loop.run_in_executor(None, self.forward, input_tensor)

            # Get logits for the last position
            next_logits = logits[0, -1, :].float()

            # Sample
            next_token_id = self._sample_next_token(
                next_logits,
                temperature=temperature,
                top_p=top_p,
                repetition_penalty=repetition_penalty,
                generated_ids=generated_ids,
            )

            # Check EOS
            if eos_token_id is not None and next_token_id == eos_token_id:
                break

            generated_ids.append(next_token_id)

            # Decode just the new token
            token_text = tokenizer.decode(
                [next_token_id], skip_special_tokens=True
            )
            if token_text:
                yield token_text

    async def generate(
        self,
        prompt: str,
        max_new_tokens: int = 512,
        temperature: float = 0.7,
        top_p: float = 0.9,
        repetition_penalty: float = 1.15,
    ) -> str:
        """Generate a full response (non-streaming).

        Args:
            prompt:             The input text prompt.
            max_new_tokens:     Maximum number of tokens to generate.
            temperature:        Sampling temperature.
            top_p:              Nucleus sampling threshold.
            repetition_penalty: Penalty for repeated tokens.

        Returns:
            The complete generated text.
        """
        tokens: list[str] = []
        async for token in self.generate_stream(
            prompt,
            max_new_tokens=max_new_tokens,
            temperature=temperature,
            top_p=top_p,
            repetition_penalty=repetition_penalty,
        ):
            tokens.append(token)
        return "".join(tokens)
