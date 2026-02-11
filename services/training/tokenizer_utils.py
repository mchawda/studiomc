"""Tokenizer utilities for training data preparation.

Provides token counting via tiktoken and functions to parse various
extract formats (Q&A pairs, facts, glossary, rules, document content)
into structured instruction-tuning samples.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, asdict

logger = logging.getLogger("training.tokenizer_utils")

# ---------------------------------------------------------------------------
# Token counting
# ---------------------------------------------------------------------------

try:
    import tiktoken

    _ENCODER = tiktoken.get_encoding("cl100k_base")
    _HAS_TIKTOKEN = True
except Exception:
    _ENCODER = None
    _HAS_TIKTOKEN = False


def count_tokens(text: str) -> int:
    """Return an approximate token count for *text*.

    Uses tiktoken cl100k_base when available; falls back to a simple
    whitespace heuristic (words × 1.3) otherwise.
    """
    if not text:
        return 0
    if _HAS_TIKTOKEN and _ENCODER is not None:
        return len(_ENCODER.encode(text))
    # Rough heuristic: ~1.3 tokens per whitespace-separated word
    return int(len(text.split()) * 1.3)


# ---------------------------------------------------------------------------
# Training sample dataclass
# ---------------------------------------------------------------------------


@dataclass
class TrainingSample:
    """One instruction-tuning example."""

    instruction: str
    input: str  # noqa: A003 — shadow builtin is fine for a dataclass field
    output: str

    def to_dict(self) -> dict[str, str]:
        return asdict(self)

    def to_prompt(self, include_response: bool = True) -> str:
        """Format as a single string suitable for causal-LM training."""
        parts = [f"### Instruction:\n{self.instruction}"]
        if self.input:
            parts.append(f"### Input:\n{self.input}")
        if include_response:
            parts.append(f"### Response:\n{self.output}")
        else:
            parts.append("### Response:\n")
        return "\n\n".join(parts)


# ---------------------------------------------------------------------------
# Parsers for different extract formats
# ---------------------------------------------------------------------------

_QA_PATTERN = re.compile(
    r"Q:\s*(.+?)(?:\n|\r\n?)A:\s*(.+?)(?=\nQ:|\Z)",
    re.DOTALL | re.IGNORECASE,
)

_TERM_DEF_PATTERN = re.compile(
    r"(?:Term|Concept|Word):\s*(.+?)(?:\n|\r\n?)(?:Definition|Meaning|Explanation):\s*(.+?)(?=\n(?:Term|Concept|Word):|\Z)",
    re.DOTALL | re.IGNORECASE,
)

_BULLET_PATTERN = re.compile(r"^\s*[-*•]\s+(.+)", re.MULTILINE)

_RULE_PATTERN = re.compile(
    r"(?:Rule|Policy|Guideline)\s*\d*\s*[:\.]\s*(.+?)(?=\n(?:Rule|Policy|Guideline)|\Z)",
    re.DOTALL | re.IGNORECASE,
)


def _parse_qa_pairs(text: str) -> list[TrainingSample]:
    """Parse Q: ... A: ... formatted text."""
    samples = []
    for match in _QA_PATTERN.finditer(text):
        question = match.group(1).strip()
        answer = match.group(2).strip()
        if question and answer:
            samples.append(
                TrainingSample(
                    instruction=question,
                    input="",
                    output=answer,
                )
            )
    return samples


def _parse_term_definitions(text: str) -> list[TrainingSample]:
    """Parse Term: ... Definition: ... formatted text."""
    samples = []
    for match in _TERM_DEF_PATTERN.finditer(text):
        term = match.group(1).strip()
        definition = match.group(2).strip()
        if term and definition:
            samples.append(
                TrainingSample(
                    instruction=f"Define the term: {term}",
                    input="",
                    output=definition,
                )
            )
    return samples


def _parse_bullet_facts(text: str) -> list[TrainingSample]:
    """Parse bullet-point facts into Q&A samples."""
    samples = []
    facts = _BULLET_PATTERN.findall(text)
    for fact in facts:
        fact = fact.strip()
        if len(fact) < 10:
            continue
        # Create a "recall this fact" instruction
        samples.append(
            TrainingSample(
                instruction="What is the following fact or piece of information?",
                input=fact[:60] + "..." if len(fact) > 60 else fact,
                output=fact,
            )
        )
    return samples


def _parse_rules(text: str) -> list[TrainingSample]:
    """Parse Rule: ... formatted text."""
    samples = []
    for match in _RULE_PATTERN.finditer(text):
        rule = match.group(1).strip()
        if rule and len(rule) > 10:
            samples.append(
                TrainingSample(
                    instruction="What is the relevant rule or policy?",
                    input="",
                    output=rule,
                )
            )
    return samples


def _chunk_document_text(text: str, chunk_size: int = 512) -> list[TrainingSample]:
    """Split plain document text into overlapping chunks for training.

    Creates instruction-tuning samples that teach the model to recall
    and discuss the document content.
    """
    samples = []
    # Split by paragraphs first
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]

    current_chunk: list[str] = []
    current_tokens = 0

    for para in paragraphs:
        para_tokens = count_tokens(para)

        if current_tokens + para_tokens > chunk_size and current_chunk:
            chunk_text = "\n\n".join(current_chunk)
            samples.append(
                TrainingSample(
                    instruction="Based on the following content, provide a detailed and accurate summary.",
                    input=chunk_text,
                    output=chunk_text,  # Self-supervised: the model learns to reproduce/recall the content
                )
            )
            # Keep last paragraph for overlap
            current_chunk = current_chunk[-1:]
            current_tokens = count_tokens(current_chunk[0]) if current_chunk else 0

        current_chunk.append(para)
        current_tokens += para_tokens

    # Final chunk
    if current_chunk:
        chunk_text = "\n\n".join(current_chunk)
        samples.append(
            TrainingSample(
                instruction="Based on the following content, provide a detailed and accurate summary.",
                input=chunk_text,
                output=chunk_text,
            )
        )

    return samples


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


def format_training_samples(text: str) -> list[TrainingSample]:
    """Auto-detect format and parse *text* into instruction-tuning samples.

    Tries structured formats first (Q&A, terms, rules), then falls back
    to chunking plain document text.  Returns an empty list only when the
    input contains no usable content.
    """
    if not text or not text.strip():
        return []

    samples: list[TrainingSample] = []

    # Try structured formats (they are not mutually exclusive)
    qa = _parse_qa_pairs(text)
    if qa:
        samples.extend(qa)
        logger.info("Parsed %d Q&A pairs", len(qa))

    terms = _parse_term_definitions(text)
    if terms:
        samples.extend(terms)
        logger.info("Parsed %d term definitions", len(terms))

    rules = _parse_rules(text)
    if rules:
        samples.extend(rules)
        logger.info("Parsed %d rules", len(rules))

    bullets = _parse_bullet_facts(text)
    if bullets:
        samples.extend(bullets)
        logger.info("Parsed %d bullet-point facts", len(bullets))

    # If no structured content was found, treat as plain document text
    if not samples:
        samples = _chunk_document_text(text)
        logger.info("Chunked document text into %d training samples", len(samples))

    return samples


def samples_to_jsonl(samples: list[TrainingSample]) -> str:
    """Serialize samples to JSONL string (one JSON object per line)."""
    lines = [json.dumps(s.to_dict(), ensure_ascii=False) for s in samples]
    return "\n".join(lines)


def load_samples_from_jsonl(jsonl_text: str) -> list[TrainingSample]:
    """Deserialize JSONL string back to TrainingSample list."""
    samples = []
    for line in jsonl_text.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            samples.append(
                TrainingSample(
                    instruction=obj.get("instruction", ""),
                    input=obj.get("input", ""),
                    output=obj.get("output", ""),
                )
            )
        except json.JSONDecodeError:
            continue
    return samples
