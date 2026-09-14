# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""LLM-driven memory extraction.

Given an assistant turn (user message + assistant reply), prompt the
local model to emit zero or more JSON memory candidates. The extractor
is *strictly opportunistic*: any LLM error, malformed JSON, or empty
response is treated as "no memories" — never raises to the caller.

We intentionally keep the prompt short and prescriptive to maximise the
hit rate of small local models.
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

import httpx

from common.config import INFERENCE_PORT, service_url

logger = logging.getLogger("memory.extractor")

INFERENCE_URL = service_url(INFERENCE_PORT, "/v1/chat/completions")

EXTRACTION_PROMPT = """\
You are a memory extractor for a personal AI assistant. Read the
conversation turn below and decide whether anything in it should be
remembered for future conversations with this user.

Only extract memories that are:
* Stable user preferences (e.g. "prefers responses in metric units").
* Personal facts about the user (e.g. "is a software engineer").
* Long-lived project context (e.g. "is building Studiomc, a local AI app").

Do NOT extract:
* Transient task state.
* Anything obviously sensitive (financial details, passwords, PII the
  user did not explicitly ask to remember).
* Generic factual statements about the world.

Respond with ONLY a JSON array (possibly empty), no prose. Each item
must be:
  {"key": "<short_label>", "content": "<one-sentence memory>", "tags": ["..."], "confidence": 0.0-1.0}

Conversation turn:
USER: {user}
ASSISTANT: {assistant}

JSON memories:
"""


_JSON_FENCE_RE = re.compile(r"```(?:json)?\s*([\s\S]+?)\s*```", re.IGNORECASE)


async def extract_memories(
    user_message: str,
    assistant_message: str,
    *,
    timeout: float = 12.0,
    max_memories: int = 5,
) -> list[dict[str, Any]]:
    """Return raw memory dicts from the LLM. Empty list on any failure."""
    if not user_message.strip() or not assistant_message.strip():
        return []

    prompt = EXTRACTION_PROMPT.format(
        user=user_message.strip()[:1500],
        assistant=assistant_message.strip()[:1500],
    )
    body = {
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.0,
        "max_tokens": 400,
        "stream": False,
    }

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(INFERENCE_URL, json=body)
        if resp.status_code != 200:
            logger.debug("Extractor inference HTTP %d", resp.status_code)
            return []
        data = resp.json()
    except Exception:
        logger.debug("Extractor inference call failed", exc_info=True)
        return []

    text = _first_completion_text(data)
    if not text:
        return []

    payload_str = _strip_to_json_array(text)
    try:
        parsed = json.loads(payload_str)
    except json.JSONDecodeError:
        logger.debug("Extractor returned non-JSON: %s", text[:120])
        return []

    if not isinstance(parsed, list):
        return []

    cleaned: list[dict[str, Any]] = []
    for raw in parsed[:max_memories]:
        if not isinstance(raw, dict):
            continue
        content = str(raw.get("content") or "").strip()
        if not content:
            continue
        try:
            confidence = float(raw.get("confidence") or 0.6)
        except (TypeError, ValueError):
            confidence = 0.6
        tags_raw = raw.get("tags") or []
        if isinstance(tags_raw, str):
            tags_raw = [tags_raw]
        tags = [str(t).strip().lower() for t in tags_raw if str(t).strip()]
        cleaned.append(
            {
                "key": str(raw.get("key") or "").strip()[:40] or None,
                "content": content[:500],
                "tags": tags[:8],
                "confidence": max(0.0, min(1.0, confidence)),
            }
        )
    return cleaned


def _first_completion_text(payload: Any) -> str:
    if not isinstance(payload, dict):
        return ""
    choices = payload.get("choices") or []
    if not choices:
        return ""
    first = choices[0]
    if not isinstance(first, dict):
        return ""
    msg = first.get("message") or {}
    return str(msg.get("content") or "")


def _strip_to_json_array(text: str) -> str:
    fence = _JSON_FENCE_RE.search(text)
    if fence:
        text = fence.group(1)
    text = text.strip()
    # Trim leading/trailing prose around the array.
    start = text.find("[")
    end = text.rfind("]")
    if start != -1 and end != -1 and end > start:
        return text[start : end + 1]
    return text
