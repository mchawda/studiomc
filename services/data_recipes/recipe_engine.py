# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Recipe Engine — transforms raw text into training-ready datasets.

Supported transforms:
  - qa_pairs:     Generate question-answer pairs from content
  - summarize:    Generate summary pairs (passage → summary)
  - instruct:     Generate instruction-response pairs
  - terms:        Extract term-definition pairs
  - raw_chunks:   Split into chunks for continued pretraining

Output formats:
  - jsonl_chat:   {"messages": [{"role": ..., "content": ...}]}
  - alpaca:       {"instruction": ..., "input": ..., "output": ...}
  - sharegpt:     {"conversations": [{"from": ..., "value": ...}]}
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any

logger = logging.getLogger("data_recipes.engine")


class TransformType(str, Enum):
    QA_PAIRS = "qa_pairs"
    SUMMARIZE = "summarize"
    INSTRUCT = "instruct"
    TERMS = "terms"
    RAW_CHUNKS = "raw_chunks"


class OutputFormat(str, Enum):
    JSONL_CHAT = "jsonl_chat"
    ALPACA = "alpaca"
    SHAREGPT = "sharegpt"


@dataclass
class RecipeSample:
    """A single training sample."""

    instruction: str
    input_text: str = ""
    output_text: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass
class RecipeResult:
    """Result of a recipe transform."""

    success: bool
    samples: list[RecipeSample]
    format: OutputFormat
    output_text: str = ""
    error: str | None = None
    stats: dict[str, Any] = field(default_factory=dict)


def _chunk_text(text: str, chunk_size: int = 1000, overlap: int = 200) -> list[str]:
    """Split text into overlapping chunks."""
    words = text.split()
    chunks: list[str] = []
    i = 0
    while i < len(words):
        chunk = " ".join(words[i : i + chunk_size])
        chunks.append(chunk)
        i += chunk_size - overlap
    return chunks


def _extract_qa_heuristic(text: str) -> list[RecipeSample]:
    """Extract Q&A pairs using heuristic patterns."""
    samples: list[RecipeSample] = []

    # Pattern 1: "Q: ... A: ..."
    qa_pattern = re.compile(
        r"(?:Q|Question|q)\s*[:\.]\s*(.+?)[\n\r]+\s*(?:A|Answer|a)\s*[:\.]\s*(.+?)(?=\n\s*(?:Q|Question|q)\s*[:\.]|\Z)",
        re.DOTALL | re.IGNORECASE,
    )
    for m in qa_pattern.finditer(text):
        q = m.group(1).strip()
        a = m.group(2).strip()
        if len(q) > 10 and len(a) > 10:
            samples.append(RecipeSample(instruction=q, output_text=a))

    if samples:
        return samples

    # Pattern 2: paragraph-based — generate a question from each paragraph
    paragraphs = [p.strip() for p in text.split("\n\n") if len(p.strip()) > 50]
    for para in paragraphs[:50]:
        first_sentence = para.split(".")[0].strip() + "."
        if len(first_sentence) > 20:
            samples.append(
                RecipeSample(
                    instruction=f"What do you know about: {first_sentence}",
                    input_text="",
                    output_text=para,
                )
            )

    return samples


def _extract_terms_heuristic(text: str) -> list[RecipeSample]:
    """Extract term-definition pairs."""
    samples: list[RecipeSample] = []

    # Pattern: "Term: ... Definition: ..."
    td_pattern = re.compile(
        r"(?:Term|Concept)\s*[:]\s*(.+?)[\n\r]+\s*(?:Definition|Meaning|Explanation)\s*[:]\s*(.+?)(?=\n\s*(?:Term|Concept)\s*[:]|\Z)",
        re.DOTALL | re.IGNORECASE,
    )
    for m in td_pattern.finditer(text):
        term = m.group(1).strip()
        defn = m.group(2).strip()
        if term and defn:
            samples.append(
                RecipeSample(
                    instruction=f"Define: {term}",
                    output_text=defn,
                )
            )

    # Fallback: "- **term**: definition" (markdown)
    if not samples:
        md_pattern = re.compile(
            r"[-*]\s*\*\*(.+?)\*\*\s*[:—-]\s*(.+?)(?=\n[-*]|\Z)",
            re.DOTALL,
        )
        for m in md_pattern.finditer(text):
            term = m.group(1).strip()
            defn = m.group(2).strip()
            if term and defn:
                samples.append(
                    RecipeSample(instruction=f"Define: {term}", output_text=defn)
                )

    return samples


def _generate_instruction_pairs(text: str) -> list[RecipeSample]:
    """Generate instruction-response pairs from paragraphs."""
    samples: list[RecipeSample] = []
    paragraphs = [p.strip() for p in text.split("\n\n") if len(p.strip()) > 80]

    prompts = [
        "Summarize the following text:",
        "Explain the key points of:",
        "What are the main takeaways from:",
        "Provide a brief overview of:",
    ]

    for i, para in enumerate(paragraphs[:50]):
        prompt = prompts[i % len(prompts)]
        samples.append(
            RecipeSample(
                instruction=prompt,
                input_text=para,
                output_text=para[:500],
            )
        )

    return samples


def _format_samples(
    samples: list[RecipeSample], fmt: OutputFormat
) -> str:
    """Convert samples to the requested output format."""
    lines: list[str] = []

    for s in samples:
        if fmt == OutputFormat.JSONL_CHAT:
            messages = [{"role": "user", "content": s.instruction}]
            if s.input_text:
                messages[0]["content"] += f"\n\n{s.input_text}"
            messages.append({"role": "assistant", "content": s.output_text})
            lines.append(json.dumps({"messages": messages}))

        elif fmt == OutputFormat.ALPACA:
            lines.append(
                json.dumps(
                    {
                        "instruction": s.instruction,
                        "input": s.input_text,
                        "output": s.output_text,
                    }
                )
            )

        elif fmt == OutputFormat.SHAREGPT:
            convos = [
                {"from": "human", "value": s.instruction},
            ]
            if s.input_text:
                convos[0]["value"] += f"\n\n{s.input_text}"
            convos.append({"from": "gpt", "value": s.output_text})
            lines.append(json.dumps({"conversations": convos}))

    return "\n".join(lines)


def run_recipe(
    text: str,
    transform: TransformType,
    output_format: OutputFormat = OutputFormat.JSONL_CHAT,
) -> RecipeResult:
    """Execute a data recipe transform on raw text.

    This is the heuristic-only path. For LLM-powered generation,
    the route layer calls the local inference service.
    """
    samples: list[RecipeSample] = []

    if transform == TransformType.QA_PAIRS:
        samples = _extract_qa_heuristic(text)
    elif transform == TransformType.TERMS:
        samples = _extract_terms_heuristic(text)
    elif transform == TransformType.INSTRUCT:
        samples = _generate_instruction_pairs(text)
    elif transform == TransformType.SUMMARIZE:
        samples = _generate_instruction_pairs(text)
        for s in samples:
            s.instruction = "Summarize the following passage:"
    elif transform == TransformType.RAW_CHUNKS:
        chunks = _chunk_text(text, chunk_size=500, overlap=50)
        for chunk in chunks:
            samples.append(
                RecipeSample(
                    instruction="Continue:",
                    output_text=chunk,
                )
            )

    if not samples:
        return RecipeResult(
            success=False,
            samples=[],
            format=output_format,
            error="No training samples could be extracted from the input.",
        )

    output = _format_samples(samples, output_format)

    logger.info(
        "Recipe complete: transform=%s, format=%s, samples=%d",
        transform.value,
        output_format.value,
        len(samples),
    )

    return RecipeResult(
        success=True,
        samples=samples,
        format=output_format,
        output_text=output,
        stats={
            "num_samples": len(samples),
            "transform": transform.value,
            "output_format": output_format.value,
            "input_chars": len(text),
        },
    )
