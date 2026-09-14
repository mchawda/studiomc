# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Studiomc 4B pipeline: formatter, registry, Autopilot, Unsloth guard.

No GPU. Unsloth/torch must not be required to import or unit-test.
"""

from __future__ import annotations

import builtins
import json
import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from common.schemas import HardwareInfo, ModelSource
from model_manager import autopilot
from model_manager.registry import (
    CURATED_BY_ID,
    CURATED_MODELS,
    STUDIOMC_4B_ID,
    is_desktop_default_candidate,
    is_studiomc_specialized,
)
from training.studiomc_model import (
    BASE_MODEL_ID,
    SPECIALIZED_MODEL_ID,
    case_to_messages,
    case_to_sft_row,
    cases_from_eval_harness,
    format_assistant,
    generate_sft_rows,
    load_cases,
    load_seed_cases,
    normalize_eval_record,
)
from training.studiomc_model.cli import main as cli_main
from training.studiomc_model.schema import EvalCase, EvidenceChunk, ExpectedToolCall

EVAL_GOLD = Path(__file__).resolve().parent.parent / "eval" / "data" / "gold.jsonl"
EVAL_CORPUS = Path(__file__).resolve().parent.parent / "eval" / "data" / "corpus.json"


def _desktop_hw(*, ram_gb: int, vram_gb: int = 0) -> HardwareInfo:
    return HardwareInfo(
        gpu_name="test-gpu" if vram_gb else None,
        vram_bytes=vram_gb * 1024**3 if vram_gb else None,
        ram_bytes=ram_gb * 1024**3,
        cpu_name="test-cpu",
        cpu_cores=8,
        disk_type="nvme",
        disk_read_mbps=2500.0,
        hw_fingerprint="test",
    )


def test_base_model_is_qwen3_instruct_2507() -> None:
    assert BASE_MODEL_ID == "Qwen/Qwen3-4B-Instruct-2507"
    assert SPECIALIZED_MODEL_ID == "studiomc-4b"
    assert SPECIALIZED_MODEL_ID == STUDIOMC_4B_ID


def test_registry_lists_studiomc_4b() -> None:
    model = CURATED_BY_ID[STUDIOMC_4B_ID]
    assert model.name == "Studiomc 4B"
    assert model.source is ModelSource.hf
    assert model.source_ref == "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF"
    assert model.params_billion == 4.0
    assert 2 * 1024**3 <= (model.disk_bytes or 0) <= 4 * 1024**3
    assert is_studiomc_specialized(model)
    assert is_desktop_default_candidate(model)
    assert CURATED_MODELS[0].id == STUDIOMC_4B_ID
    card = json.loads(model.manifest_json or "{}")
    assert card["base"] == BASE_MODEL_ID
    assert "citations" in card["specialization"]


def test_seed_fixtures_cover_task_mix() -> None:
    cases = load_seed_cases()
    tasks = {c.task for c in cases}
    assert {"grounded_qa", "refuse", "tool_plan", "tool_call"} <= tasks
    assert len(cases) >= 16


def test_formatter_grounded_qa_uses_source_n() -> None:
    case = EvalCase(
        id="t-qa",
        task="grounded_qa",
        question="How long are logs kept?",
        evidence=[
            EvidenceChunk(
                doc_id="pol-1",
                filename="privacy.md",
                chunk_index=0,
                text="Logs are retained for 30 days.",
            )
        ],
        expected_answer="Logs are retained for 30 days. [Source 1]",
    )
    user = case_to_messages(case)[1]["content"]
    assistant = format_assistant(case)
    assert "[Source 1 | doc=pol-1 chunk=0" in user
    assert "### Question\nHow long are logs kept?" in user
    assert "[Source 1]" in assistant


def test_formatter_refuse_when_evidence_missing() -> None:
    case = EvalCase(
        id="t-ref",
        task="refuse",
        question="What is the CEO phone number?",
        refuse=True,
    )
    assistant = format_assistant(case)
    assert "cannot answer" in assistant.lower()
    row = case_to_sft_row(case)
    assert row["eval"]["refuse"] is True


def test_formatter_lre_tool_plan_is_json_array() -> None:
    case = EvalCase(
        id="t-plan",
        task="tool_plan",
        question="Find the retention rule.",
        tool_calls=[
            ExpectedToolCall("search", {"query": "retention", "scope": "default"}),
            ExpectedToolCall("inference", {"query": "Find the retention rule."}),
        ],
    )
    out = json.loads(format_assistant(case))
    assert out[0]["tool"] == "search"
    assert out[0]["params"]["query"] == "retention"
    assert out[-1]["tool"] == "inference"


def test_formatter_lre_tool_call_wraps_xml() -> None:
    case = EvalCase(
        id="t-call",
        task="tool_call",
        question="Cite chunk 0 of pol-1.",
        tool_calls=[
            ExpectedToolCall(
                "cite",
                {"doc_id": "pol-1", "chunk_index": 0, "snippet": "local device"},
            )
        ],
    )
    text = format_assistant(case)
    assert text.startswith("<tool_call>")
    assert text.endswith("</tool_call>")
    inner = json.loads(text.split("<tool_call>", 1)[1].split("</tool_call>", 1)[0])
    assert inner["tool"] == "cite"
    assert inner["params"]["doc_id"] == "pol-1"


def test_normalize_eval_harness_aliases() -> None:
    case = normalize_eval_record(
        {
            "id": "alias-1",
            "query": "Who signed the contract?",
            "contexts": [
                {
                    "document_id": "doc-1",
                    "filename": "c.md",
                    "chunk_index": 2,
                    "snippet": "Jane signed on 1 May.",
                }
            ],
            "gold": "Jane signed on 1 May. [Source 1]",
            "labels": ["cite"],
        }
    )
    assert case.question.startswith("Who signed")
    assert case.task == "grounded_qa"
    assert case.evidence[0].text == "Jane signed on 1 May."
    assert case.expected_answer is not None


def test_cases_from_eval_harness_gold() -> None:
    if not EVAL_GOLD.is_file() or not EVAL_CORPUS.is_file():
        pytest.skip("eval harness gold/corpus not present")
    cases = cases_from_eval_harness(EVAL_GOLD, EVAL_CORPUS)
    assert cases
    refuse = [c for c in cases if c.refuse]
    grounded = [c for c in cases if c.task == "grounded_qa"]
    assert refuse
    assert grounded
    assert any(c.evidence and "[Source 1]" in (c.expected_answer or "") for c in grounded)
    # Join actually pulled corpus text, not just chunk ids.
    assert any("Helios" in (c.evidence[0].text if c.evidence else "") for c in grounded)


def test_generate_sft_rows_includes_eval_when_present() -> None:
    rows = generate_sft_rows()
    ids = {r["id"] for r in rows}
    assert "qa-retention" in ids
    if EVAL_GOLD.is_file():
        assert "ans-001" in ids
    for row in rows:
        assert row["messages"][0]["role"] == "system"
        assert row["messages"][-1]["role"] == "assistant"


def test_load_cases_detects_eval_gold(tmp_path: Path) -> None:
    if not EVAL_GOLD.is_file():
        pytest.skip("eval gold missing")
    cases = load_cases(EVAL_GOLD, corpus_path=EVAL_CORPUS)
    assert any(c.id == "unk-001" and c.refuse for c in cases)


def test_package_import_is_torch_free(monkeypatch: pytest.MonkeyPatch) -> None:
    """``training.studiomc_model`` public surface must not import Pro ML libs."""
    attempted: list[str] = []
    original: Callable[..., object] = builtins.__import__
    blocked = {"torch", "unsloth", "transformers", "peft", "trl", "datasets"}

    def guarded(name: str, *args: object, **kwargs: object) -> object:
        root = name.split(".", 1)[0]
        if root in blocked:
            attempted.append(name)
            raise ImportError(f"blocked {name}")
        return original(name, *args, **kwargs)  # type: ignore[arg-type]

    for mod in list(sys.modules):
        if mod.split(".", 1)[0] in blocked or mod.startswith("training.studiomc_model"):
            sys.modules.pop(mod, None)

    monkeypatch.setattr(builtins, "__import__", guarded)
    import training.studiomc_model as pkg

    assert pkg.SPECIALIZED_MODEL_ID == "studiomc-4b"
    assert not attempted, f"public package imported Pro modules: {attempted}"


def test_require_unsloth_raises_when_missing(monkeypatch: pytest.MonkeyPatch) -> None:
    original: Callable[..., object] = builtins.__import__

    def blocked(name: str, *args: object, **kwargs: object) -> object:
        if name.split(".", 1)[0] == "unsloth":
            raise ImportError("blocked")
        return original(name, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(builtins, "__import__", blocked)
    sys.modules.pop("unsloth", None)
    from training.studiomc_model import unsloth_trainer as ut

    assert ut.unsloth_available() is False
    with pytest.raises(ut.UnslothUnavailableError, match="not installed"):
        ut.require_unsloth()
    with pytest.raises(ut.UnslothUnavailableError):
        ut.train(
            ut.TrainJob(
                data_path=Path("/tmp/does-not-exist.jsonl"),
                output_dir=Path("/tmp/out"),
            )
        )


def test_autopilot_prefers_studiomc_4b_on_desktop() -> None:
    result = autopilot.recommend(_desktop_hw(ram_gb=16), user_intent="chat")
    assert result.recommended
    assert result.recommended[0].model_id == STUDIOMC_4B_ID
    assert result.recommended[0].recommended is True


def test_autopilot_skips_studiomc_4b_when_ram_too_small() -> None:
    result = autopilot.recommend(_desktop_hw(ram_gb=2), user_intent="chat")
    ids = [r.model_id for r in result.recommended]
    overflow = [r.model_id for r in result.bigger_slower]
    assert STUDIOMC_4B_ID not in ids
    assert STUDIOMC_4B_ID not in overflow


def test_autopilot_does_not_force_70b_as_default() -> None:
    result = autopilot.recommend(_desktop_hw(ram_gb=16), user_intent=None)
    assert result.recommended
    assert result.recommended[0].model_id != "llama-3.1-70b-q4km"
    assert (result.recommended[0].disk_bytes or 0) < 8 * 1024**3


def test_cli_dry_run_exits_zero(capsys: pytest.CaptureFixture[str]) -> None:
    assert cli_main(["dry-run"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["rows"] >= 16
    assert payload["catalog_id"] == "studiomc-4b"
    assert payload["unsloth"] in (True, False)


def test_cli_generate_writes_jsonl(tmp_path: Path) -> None:
    dest = tmp_path / "sft.jsonl"
    assert cli_main(["generate", "--out", str(dest), "--fixtures-only"]) == 0
    lines = [json.loads(line) for line in dest.read_text(encoding="utf-8").splitlines() if line]
    assert lines
    assert lines[0]["messages"][1]["role"] == "user"
