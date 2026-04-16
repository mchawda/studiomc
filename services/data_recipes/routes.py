# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Data Recipes API routes.

Endpoints:
  POST /recipes/generate        — Generate training data from text/documents
  POST /recipes/generate-llm    — LLM-powered dataset generation (uses local inference)
  GET  /recipes/transforms      — List available transforms
  GET  /recipes/formats         — List available output formats
  POST /recipes/preview         — Preview generated samples before committing
  GET  /health                  — Health check
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from common.config import ADAPTERS_DIR
from common.database import Database
from data_recipes.recipe_engine import (
    OutputFormat,
    RecipeResult,
    RecipeSample,
    TransformType,
    run_recipe,
)

logger = logging.getLogger("data_recipes.routes")

router = APIRouter(prefix="/recipes")


class GenerateRequest(BaseModel):
    text: str | None = None
    document_ids: list[str] | None = None
    collection_ids: list[str] | None = None
    transform: TransformType = TransformType.QA_PAIRS
    output_format: OutputFormat = OutputFormat.JSONL_CHAT
    max_samples: int = 100


class LLMGenerateRequest(BaseModel):
    text: str | None = None
    document_ids: list[str] | None = None
    collection_ids: list[str] | None = None
    transform: TransformType = TransformType.QA_PAIRS
    output_format: OutputFormat = OutputFormat.JSONL_CHAT
    max_samples: int = 50
    model_id: str | None = None


class RecipeResponse(BaseModel):
    success: bool
    num_samples: int
    output_format: str
    output_text: str
    samples_preview: list[dict[str, Any]]
    stats: dict[str, Any]
    error: str | None = None
    recipe_id: str | None = None


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "data_recipes"}


@router.get("/transforms")
async def list_transforms() -> list[dict[str, str]]:
    return [
        {
            "id": "qa_pairs",
            "label": "Question & Answer Pairs",
            "description": "Generate Q&A pairs from document content",
        },
        {
            "id": "summarize",
            "label": "Summarization Pairs",
            "description": "Generate passage-summary pairs for training",
        },
        {
            "id": "instruct",
            "label": "Instruction-Response",
            "description": "Generate instruction-following training pairs",
        },
        {
            "id": "terms",
            "label": "Terms & Definitions",
            "description": "Extract term-definition pairs from content",
        },
        {
            "id": "raw_chunks",
            "label": "Raw Chunks",
            "description": "Split content into chunks for continued pretraining",
        },
    ]


@router.get("/formats")
async def list_formats() -> list[dict[str, str]]:
    return [
        {
            "id": "jsonl_chat",
            "label": "JSONL Chat",
            "description": "OpenAI chat format — {messages: [{role, content}]}",
        },
        {
            "id": "alpaca",
            "label": "Alpaca",
            "description": "Stanford Alpaca format — {instruction, input, output}",
        },
        {
            "id": "sharegpt",
            "label": "ShareGPT",
            "description": "ShareGPT format — {conversations: [{from, value}]}",
        },
    ]


async def _gather_text(
    text: str | None,
    document_ids: list[str] | None,
    collection_ids: list[str] | None,
) -> str:
    """Gather text from direct input, document IDs, or collection IDs."""
    if text:
        return text

    db = await Database.instance()
    parts: list[str] = []

    if collection_ids:
        for cid in collection_ids:
            rows = await db.fetchall(
                """
                SELECT dc.text FROM doc_chunks dc
                JOIN collection_documents cd ON cd.document_id = dc.document_id
                WHERE cd.collection_id = ?
                ORDER BY dc.document_id, dc.chunk_index
                """,
                (cid,),
            )
            parts.extend(row["text"] for row in rows if row["text"])

    if document_ids:
        for doc_id in document_ids:
            row = await db.fetchone(
                "SELECT content FROM document_content WHERE document_id = ?",
                (doc_id,),
            )
            if row and row["content"]:
                parts.append(row["content"])

    return "\n\n".join(parts)


@router.post("/generate", response_model=RecipeResponse)
async def generate_dataset(req: GenerateRequest) -> RecipeResponse:
    """Generate training data using heuristic transforms."""
    text = await _gather_text(req.text, req.document_ids, req.collection_ids)
    if not text.strip():
        raise HTTPException(status_code=400, detail="No input text provided")

    result = run_recipe(text, req.transform, req.output_format)

    if not result.success:
        return RecipeResponse(
            success=False,
            num_samples=0,
            output_format=req.output_format.value,
            output_text="",
            samples_preview=[],
            stats={},
            error=result.error,
        )

    preview = [
        {
            "instruction": s.instruction,
            "input": s.input_text,
            "output": s.output_text[:200],
        }
        for s in result.samples[:10]
    ]

    recipe_id = f"recipe-{uuid.uuid4().hex[:8]}"

    return RecipeResponse(
        success=True,
        num_samples=len(result.samples),
        output_format=req.output_format.value,
        output_text=result.output_text,
        samples_preview=preview,
        stats=result.stats,
        recipe_id=recipe_id,
    )


@router.post("/generate-llm", response_model=RecipeResponse)
async def generate_dataset_llm(req: LLMGenerateRequest) -> RecipeResponse:
    """Generate training data using the local LLM for higher quality."""
    text = await _gather_text(req.text, req.document_ids, req.collection_ids)
    if not text.strip():
        raise HTTPException(status_code=400, detail="No input text provided")

    # Use the local inference service
    from data_recipes.recipe_engine import _chunk_text

    chunks = _chunk_text(text, chunk_size=500, overlap=50)
    samples: list[dict[str, Any]] = []

    transform_prompts = {
        TransformType.QA_PAIRS: (
            "Generate 3-5 question-answer pairs from the following text. "
            "Format each pair as:\nQ: [question]\nA: [answer]\n\nText:\n{chunk}"
        ),
        TransformType.SUMMARIZE: (
            "Summarize the following text in 2-3 sentences:\n\n{chunk}"
        ),
        TransformType.INSTRUCT: (
            "Generate 2-3 instruction-response pairs based on this text. "
            "Format each as:\nInstruction: [instruction]\nResponse: [response]\n\nText:\n{chunk}"
        ),
        TransformType.TERMS: (
            "Extract key terms and their definitions from this text. "
            "Format each as:\nTerm: [term]\nDefinition: [definition]\n\nText:\n{chunk}"
        ),
    }

    prompt_template = transform_prompts.get(
        req.transform,
        "Generate training data from:\n{chunk}",
    )

    async with httpx.AsyncClient(timeout=120.0) as client:
        for chunk in chunks[: req.max_samples]:
            prompt = prompt_template.format(chunk=chunk)
            try:
                resp = await client.post(
                    "http://127.0.0.1:8100/v1/chat/completions",
                    json={
                        "messages": [{"role": "user", "content": prompt}],
                        "stream": False,
                        "max_tokens": 1024,
                    },
                )
                if resp.status_code == 200:
                    body = resp.json()
                    content = (
                        body.get("choices", [{}])[0]
                        .get("message", {})
                        .get("content", "")
                    )
                    if content:
                        samples.append(
                            {
                                "instruction": prompt[:100],
                                "input": chunk[:200],
                                "output": content,
                            }
                        )
            except Exception as e:
                logger.warning("LLM generation failed for chunk: %s", e)
                continue

    if not samples:
        return RecipeResponse(
            success=False,
            num_samples=0,
            output_format=req.output_format.value,
            output_text="",
            samples_preview=[],
            stats={},
            error="LLM generation produced no samples. Is a model loaded?",
        )

    # Format output
    output_lines = []
    for s in samples:
        if req.output_format == OutputFormat.JSONL_CHAT:
            output_lines.append(
                json.dumps(
                    {
                        "messages": [
                            {"role": "user", "content": s["instruction"]},
                            {"role": "assistant", "content": s["output"]},
                        ]
                    }
                )
            )
        elif req.output_format == OutputFormat.ALPACA:
            output_lines.append(
                json.dumps(
                    {
                        "instruction": s["instruction"],
                        "input": s.get("input", ""),
                        "output": s["output"],
                    }
                )
            )
        elif req.output_format == OutputFormat.SHAREGPT:
            output_lines.append(
                json.dumps(
                    {
                        "conversations": [
                            {"from": "human", "value": s["instruction"]},
                            {"from": "gpt", "value": s["output"]},
                        ]
                    }
                )
            )

    recipe_id = f"recipe-{uuid.uuid4().hex[:8]}"

    return RecipeResponse(
        success=True,
        num_samples=len(samples),
        output_format=req.output_format.value,
        output_text="\n".join(output_lines),
        samples_preview=samples[:10],
        stats={
            "num_samples": len(samples),
            "transform": req.transform.value,
            "output_format": req.output_format.value,
            "input_chars": len(text),
            "llm_powered": True,
        },
        recipe_id=recipe_id,
    )


@router.post("/preview", response_model=RecipeResponse)
async def preview_recipe(req: GenerateRequest) -> RecipeResponse:
    """Preview a recipe without saving — same as generate but limited to 5 samples."""
    req.max_samples = 5
    return await generate_dataset(req)
