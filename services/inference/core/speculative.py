# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Speculative decoding — draft-then-verify acceleration for autoregressive generation.

Implements the speculative decoding algorithm from Leviathan et al. (2023):
    1. A small/fast *draft* model generates N candidate tokens.
    2. The main (target) model verifies all N candidates in a single forward pass.
    3. Matching tokens are accepted; the first divergent token is resampled
       from the adjusted target distribution.

This can yield 2–3× speedup when the draft model is well-aligned with the
target model, because the expensive target model forward pass processes
multiple tokens at once instead of one at a time.

Falls back to standard autoregressive decoding when no draft model is
available.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from typing import AsyncIterator

import torch
import torch.nn.functional as F

from inference.core.out_of_core import OutOfCoreEngine

logger = logging.getLogger("inference.core.speculative")


@dataclass
class SpeculativeStats:
    """Performance tracking for speculative decoding."""

    total_draft_tokens: int = 0
    accepted_tokens: int = 0
    rejected_tokens: int = 0
    total_target_forward_passes: int = 0
    total_standard_forward_passes: int = 0
    draft_time_ms: int = 0
    verify_time_ms: int = 0
    total_time_ms: int = 0
    _start_time: float = field(default=0.0, repr=False)

    @property
    def acceptance_rate(self) -> float:
        """Fraction of draft tokens accepted by the target model (0–1)."""
        if self.total_draft_tokens == 0:
            return 0.0
        return self.accepted_tokens / self.total_draft_tokens

    @property
    def speedup_ratio(self) -> float:
        """Estimated speedup vs standard decoding.

        Computed as: tokens_generated / target_forward_passes.
        Standard decoding would use 1 forward pass per token (ratio = 1.0).
        """
        total_generated = self.accepted_tokens + self.rejected_tokens + self.total_standard_forward_passes
        total_passes = self.total_target_forward_passes + self.total_standard_forward_passes
        if total_passes == 0:
            return 1.0
        return total_generated / total_passes

    @property
    def tokens_per_verify(self) -> float:
        """Average number of tokens produced per target verification pass."""
        if self.total_target_forward_passes == 0:
            return 0.0
        return (self.accepted_tokens + self.total_target_forward_passes) / self.total_target_forward_passes

    def report(self) -> dict:
        """Return a summary dict for logging / API responses."""
        return {
            "acceptance_rate": round(self.acceptance_rate, 3),
            "speedup_ratio": round(self.speedup_ratio, 2),
            "tokens_per_verify": round(self.tokens_per_verify, 2),
            "total_draft_tokens": self.total_draft_tokens,
            "accepted_tokens": self.accepted_tokens,
            "rejected_tokens": self.rejected_tokens,
            "target_forward_passes": self.total_target_forward_passes,
            "standard_forward_passes": self.total_standard_forward_passes,
            "draft_time_ms": self.draft_time_ms,
            "verify_time_ms": self.verify_time_ms,
            "total_time_ms": self.total_time_ms,
        }


class SpeculativeDecoder:
    """Draft-then-verify speculative decoding engine.

    The decoder wraps a *target* :class:`OutOfCoreEngine` and an optional
    *draft* engine. When a draft model is available, generation uses the
    speculative algorithm. Otherwise, it transparently falls back to
    standard autoregressive decoding via the target engine.

    Usage::

        target = OutOfCoreEngine()
        await target.load_model("/path/to/large-model")

        draft = OutOfCoreEngine()
        await draft.load_model("/path/to/small-model")

        decoder = SpeculativeDecoder(
            target_engine=target,
            draft_engine=draft,
            num_speculative_tokens=4,
        )

        async for token in decoder.generate_stream("Hello world"):
            print(token, end="", flush=True)

        print(decoder.stats.report())
    """

    def __init__(
        self,
        target_engine: OutOfCoreEngine,
        draft_engine: OutOfCoreEngine | None = None,
        num_speculative_tokens: int = 4,
        temperature: float = 0.7,
        top_p: float = 0.9,
        repetition_penalty: float = 1.15,
    ) -> None:
        self.target = target_engine
        self.draft = draft_engine
        self.num_speculative_tokens = max(1, num_speculative_tokens)
        self.temperature = temperature
        self.top_p = top_p
        self.repetition_penalty = repetition_penalty
        self.stats = SpeculativeStats()

    @property
    def has_draft(self) -> bool:
        """True if a draft model is loaded and ready."""
        return self.draft is not None and self.draft.is_loaded

    def reset_stats(self) -> None:
        """Reset performance counters."""
        self.stats = SpeculativeStats()

    # ── Sampling helpers ─────────────────────────────────────────────

    def _sample_token(
        self,
        logits: torch.Tensor,
        generated_ids: list[int] | None = None,
    ) -> tuple[int, torch.Tensor]:
        """Sample a token and return (token_id, probability_distribution).

        Uses the same temperature + top-p sampling as OutOfCoreEngine
        but also returns the full probability distribution for acceptance
        testing.
        """
        logits = logits.float().clone()

        # Apply repetition penalty
        if generated_ids and self.repetition_penalty != 1.0:
            for token_id in set(generated_ids):
                if token_id < logits.shape[-1]:
                    if logits[token_id] > 0:
                        logits[token_id] /= self.repetition_penalty
                    else:
                        logits[token_id] *= self.repetition_penalty

        if self.temperature <= 0:
            probs = F.softmax(logits, dim=-1)
            token_id = logits.argmax(dim=-1).item()
            return token_id, probs

        # Temperature scaling
        scaled = logits / self.temperature

        # Top-p filtering
        sorted_logits, sorted_indices = torch.sort(scaled, descending=True)
        cumulative_probs = torch.cumsum(F.softmax(sorted_logits, dim=-1), dim=-1)
        sorted_mask = cumulative_probs > self.top_p
        sorted_mask[..., 1:] = sorted_mask[..., :-1].clone()
        sorted_mask[..., 0] = False
        indices_to_remove = sorted_indices[sorted_mask]
        scaled[indices_to_remove] = float("-inf")

        probs = F.softmax(scaled, dim=-1)
        token_id = torch.multinomial(probs, num_samples=1).item()
        return token_id, probs

    # ── Core speculative decode step ─────────────────────────────────

    def _speculative_step(
        self,
        input_ids: list[int],
    ) -> tuple[list[int], list[torch.Tensor]]:
        """Run one speculative decode step (synchronous, for use in executor).

        1. Draft model generates N candidate tokens greedily.
        2. Target model runs a single forward pass on all candidates.
        3. Compare draft vs target distributions; accept matching tokens.

        Returns:
            (accepted_token_ids, draft_probs_list)
        """
        draft_engine = self.draft
        target_engine = self.target

        if draft_engine is None or not draft_engine.is_loaded:
            raise RuntimeError("Draft engine not available")

        n_spec = self.num_speculative_tokens
        device = target_engine.device

        # ── Stage 1: Draft generation ────────────────────────────────
        t_draft = time.perf_counter()

        draft_token_ids: list[int] = []
        draft_probs_list: list[torch.Tensor] = []
        current_ids = list(input_ids)

        for _ in range(n_spec):
            draft_input = torch.tensor([current_ids])
            draft_logits = draft_engine.forward(draft_input)
            draft_last_logits = draft_logits[0, -1, :]
            token_id, probs = self._sample_token(draft_last_logits, current_ids)
            draft_token_ids.append(token_id)
            draft_probs_list.append(probs)
            current_ids.append(token_id)

        draft_ms = int((time.perf_counter() - t_draft) * 1000)
        self.stats.draft_time_ms += draft_ms
        self.stats.total_draft_tokens += n_spec

        # ── Stage 2: Target verification ─────────────────────────────
        t_verify = time.perf_counter()

        # Build input with all draft tokens appended
        verify_ids = list(input_ids) + draft_token_ids
        verify_input = torch.tensor([verify_ids])
        target_logits = target_engine.forward(verify_input)

        self.stats.total_target_forward_passes += 1
        verify_ms = int((time.perf_counter() - t_verify) * 1000)
        self.stats.verify_time_ms += verify_ms

        # ── Stage 3: Accept / reject ─────────────────────────────────
        accepted: list[int] = []
        original_len = len(input_ids)

        for i, draft_id in enumerate(draft_token_ids):
            # Target distribution at position where draft token was generated
            target_pos = original_len + i - 1  # logits at pos before draft token
            target_last = target_logits[0, target_pos, :].float()
            _, target_probs = self._sample_token(target_last, input_ids + accepted)

            # Draft probability for the chosen token
            draft_prob = draft_probs_list[i][draft_id].item()
            target_prob = target_probs[draft_id].item()

            # Acceptance criterion: accept with probability min(1, p_target / p_draft)
            if draft_prob <= 0:
                # Draft assigned zero probability — reject
                self.stats.rejected_tokens += 1
                break

            acceptance_ratio = target_prob / draft_prob
            if acceptance_ratio >= 1.0:
                # Target model agrees — accept
                accepted.append(draft_id)
                self.stats.accepted_tokens += 1
            else:
                # Stochastic acceptance
                if torch.rand(1).item() < acceptance_ratio:
                    accepted.append(draft_id)
                    self.stats.accepted_tokens += 1
                else:
                    self.stats.rejected_tokens += 1
                    # Resample from adjusted distribution: max(0, p_target - p_draft)
                    adjusted = torch.clamp(target_probs - draft_probs_list[i], min=0)
                    adj_sum = adjusted.sum()
                    if adj_sum > 0:
                        adjusted = adjusted / adj_sum
                        resampled_id = torch.multinomial(adjusted, num_samples=1).item()
                        accepted.append(resampled_id)
                    else:
                        # Fall back to target sampling
                        resampled_id, _ = self._sample_token(
                            target_last, input_ids + accepted
                        )
                        accepted.append(resampled_id)
                    break

        # If all draft tokens were accepted, sample one more from target
        if len(accepted) == n_spec:
            bonus_pos = original_len + n_spec - 1
            bonus_logits = target_logits[0, bonus_pos, :].float()
            bonus_id, _ = self._sample_token(bonus_logits, input_ids + accepted)
            accepted.append(bonus_id)

        return accepted, draft_probs_list

    # ── Standard (non-speculative) decode step ───────────────────────

    def _standard_step(self, input_ids: list[int]) -> int:
        """Standard single-token decode using the target model."""
        input_tensor = torch.tensor([input_ids])
        logits = self.target.forward(input_tensor)
        next_logits = logits[0, -1, :].float()
        token_id, _ = self._sample_token(next_logits, input_ids)
        self.stats.total_standard_forward_passes += 1
        return token_id

    # ── Streaming generation ─────────────────────────────────────────

    async def generate_stream(
        self,
        prompt: str,
        max_new_tokens: int = 512,
        temperature: float | None = None,
        top_p: float | None = None,
        repetition_penalty: float | None = None,
    ) -> AsyncIterator[str]:
        """Generate tokens with speculative decoding (streaming).

        Falls back to standard autoregressive decoding if no draft model
        is available.

        Args:
            prompt:             Input text.
            max_new_tokens:     Maximum tokens to generate.
            temperature:        Override instance temperature.
            top_p:              Override instance top_p.
            repetition_penalty: Override instance repetition_penalty.

        Yields:
            Individual token strings.
        """
        if not self.target.is_loaded:
            raise RuntimeError("Target model not loaded")

        # Apply overrides
        if temperature is not None:
            self.temperature = temperature
        if top_p is not None:
            self.top_p = top_p
        if repetition_penalty is not None:
            self.repetition_penalty = repetition_penalty

        self.reset_stats()
        self.stats._start_time = time.perf_counter()

        tokenizer = self.target.tokenizer
        input_ids = tokenizer.encode(prompt, return_tensors="pt")[0].tolist()
        generated_ids = list(input_ids)
        eos_token_id = getattr(tokenizer, "eos_token_id", None)
        tokens_generated = 0

        loop = asyncio.get_event_loop()

        use_speculative = self.has_draft

        while tokens_generated < max_new_tokens:
            if use_speculative:
                try:
                    # Run speculative step in executor (CPU-bound)
                    accepted, _ = await loop.run_in_executor(
                        None, self._speculative_step, list(generated_ids)
                    )
                except Exception as e:
                    logger.warning("Speculative step failed: %s — falling back to standard", e)
                    use_speculative = False
                    continue

                # Yield accepted tokens
                for token_id in accepted:
                    if eos_token_id is not None and token_id == eos_token_id:
                        self.stats.total_time_ms = int(
                            (time.perf_counter() - self.stats._start_time) * 1000
                        )
                        return

                    generated_ids.append(token_id)
                    tokens_generated += 1
                    token_text = tokenizer.decode([token_id], skip_special_tokens=True)
                    if token_text:
                        yield token_text

                    if tokens_generated >= max_new_tokens:
                        break
            else:
                # Standard decode — one token at a time
                token_id = await loop.run_in_executor(
                    None, self._standard_step, list(generated_ids)
                )

                if eos_token_id is not None and token_id == eos_token_id:
                    break

                generated_ids.append(token_id)
                tokens_generated += 1
                token_text = tokenizer.decode([token_id], skip_special_tokens=True)
                if token_text:
                    yield token_text

        self.stats.total_time_ms = int(
            (time.perf_counter() - self.stats._start_time) * 1000
        )

    async def generate(
        self,
        prompt: str,
        max_new_tokens: int = 512,
        temperature: float | None = None,
        top_p: float | None = None,
        repetition_penalty: float | None = None,
    ) -> tuple[str, dict]:
        """Generate a full response (non-streaming).

        Returns:
            (text, stats_dict) tuple.
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
        return "".join(tokens), self.stats.report()
