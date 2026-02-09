"""Studiomc's out-of-core inference engine.

Runs models of any size by streaming layers from disk through memory,
one layer at a time. Based on the out-of-core inference approach where
only a single transformer layer is resident in memory at any moment.

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
    """Detect the best available compute device."""
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


class OutOfCoreEngine:
    """Studiomc's out-of-core inference engine.

    Runs models of any size by streaming layers from disk through memory,
    one layer at a time. Based on the out-of-core inference approach.

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
        self._model_path: str | None = None

    @property
    def device(self) -> str:
        """The compute device being used."""
        return self._device

    @property
    def is_loaded(self) -> bool:
        """True if a model skeleton is loaded and ready for inference."""
        return self.model is not None and len(self.layer_names) > 0

    async def load_model(self, model_path: str) -> None:
        """Load model config and prepare for out-of-core inference.

        Does NOT load weights into memory — only the model structure.
        Uses accelerate's init_empty_weights() to create a skeleton model
        with all weights on the 'meta' device (zero memory).

        If the model hasn't been split into per-layer files yet, this
        will run the splitter first.

        Args:
            model_path: Path to the HuggingFace model directory.
        """
        from accelerate import init_empty_weights

        path = Path(model_path)
        if not path.is_dir():
            raise FileNotFoundError(f"Model directory not found: {model_path}")

        logger.info("Loading model config from %s", model_path)

        loop = asyncio.get_event_loop()

        # Step 1: Load config
        self.config = await loop.run_in_executor(
            None, lambda: AutoConfig.from_pretrained(model_path, trust_remote_code=True)
        )

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

        # Step 4: Create empty model skeleton (no memory usage)
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

    def _load_weights_into_module(
        self, module: torch.nn.Module, weights: dict[str, torch.Tensor]
    ) -> None:
        """Load weights into a module by matching parameter names.

        Handles the mapping between flat safetensors keys and nested module
        parameter names.
        """
        # Build a lookup from short param names to full weight names
        weight_lookup: dict[str, torch.Tensor] = {}
        for full_name, tensor in weights.items():
            # The weight name might have a prefix like "model.layers.5."
            # We need to match the suffix against the module's parameter names
            weight_lookup[full_name] = tensor

        for param_name, param in module.named_parameters():
            # Try to find a matching weight
            matched = False
            for weight_name, tensor in weight_lookup.items():
                if weight_name.endswith(param_name):
                    device_tensor = tensor.to(self._device, non_blocking=True)
                    param.data = device_tensor
                    matched = True
                    break

            if not matched:
                logger.debug("No weight found for parameter: %s", param_name)

    def _move_module_to_meta(self, module: torch.nn.Module) -> None:
        """Move all parameters of a module to the 'meta' device (frees memory)."""
        for param_name, param in module.named_parameters(recurse=True):
            param.data = torch.empty(0, device="meta")

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
        self._load_weights_into_module(model.model.embed_tokens, embed_weights)
        hidden_states = model.model.embed_tokens(input_ids)
        self._move_module_to_meta(model.model.embed_tokens)
        del embed_weights
        clean_memory()

        # ── Transformer layers ───────────────────────────────────────
        # Prepare position-related inputs
        position_ids = torch.arange(
            hidden_states.shape[1], dtype=torch.long, device=device
        ).unsqueeze(0)

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
            self._load_weights_into_module(layer_module, layer_weights)

            # Forward through this layer
            with torch.no_grad():
                layer_output = layer_module(
                    hidden_states,
                    position_ids=position_ids,
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
            self._load_weights_into_module(model.model.norm, norm_weights)
            hidden_states = model.model.norm(hidden_states)
            self._move_module_to_meta(model.model.norm)
            del norm_weights
            clean_memory()

        # ── LM head ─────────────────────────────────────────────────
        if "lm_head" in self.layer_names:
            lm_weights = self.loader.load_layer("lm_head")
            self._load_weights_into_module(model.lm_head, lm_weights)
            logits = model.lm_head(hidden_states)
            self._move_module_to_meta(model.lm_head)
            del lm_weights
        else:
            # Some models tie lm_head to embed_tokens
            embed_weights = self.loader.load_layer("embed_tokens")
            self._load_weights_into_module(model.model.embed_tokens, embed_weights)
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
