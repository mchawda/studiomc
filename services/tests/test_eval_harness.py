# SPDX-License-Identifier: LicenseRef-NIA-Proprietary
# Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

"""Offline grounded-answering eval: metric math and fixture suite."""

from __future__ import annotations

import json

import pytest

from eval.fixtures import load_corpus, load_gold, load_predictions
from eval.generator import REFUSAL_ANSWER, generate_stub
from eval.metrics import (
    citations_from_source_markers,
    grounding_score,
    hallucination_rate,
    is_refusal_text,
    precision_recall,
    retrieval_hit_at_k,
)
from eval.retrieval import LexicalIndex, retrieve_lexical
from eval.runner import format_table, run_live, run_offline
from eval.scorer import aggregate, score_dataset, score_prediction
from eval.types import CorpusChunk, GoldItem, Prediction, SourceRef


def _src(**kwargs: object) -> SourceRef:
    return SourceRef.from_dict(kwargs)


def _chunk(**kwargs: object) -> CorpusChunk:
    return CorpusChunk.from_dict(kwargs)


def test_source_match_by_chunk_id() -> None:
    gold = _src(chunk_id="chk-q3-0", document_id="doc-q3", chunk_index=0)
    pred = _src(chunk_id="chk-q3-0", filename="other.md", chunk_index=9)
    assert gold.matches(pred)
    assert not gold.matches(_src(chunk_id="chk-other"))


def test_source_match_by_doc_and_index() -> None:
    gold = _src(document_id="doc-q3", filename="q3-earnings.md", chunk_index=2)
    pred = _src(document_id="doc-q3", chunk_index=2)
    assert gold.matches(pred)
    assert gold.matches(_src(filename="q3-earnings.md", chunk_index=2))
    assert not gold.matches(_src(document_id="doc-q3", chunk_index=1))


def test_citation_precision_recall_perfect() -> None:
    gold = [_src(chunk_id="a"), _src(chunk_id="b")]
    pred = [_src(chunk_id="b"), _src(chunk_id="a")]
    p, r, f1 = precision_recall(pred, gold)
    assert p == 1.0
    assert r == 1.0
    assert f1 == 1.0


def test_citation_precision_recall_partial() -> None:
    gold = [_src(chunk_id="a"), _src(chunk_id="b")]
    pred = [_src(chunk_id="a"), _src(chunk_id="zzz")]
    p, r, f1 = precision_recall(pred, gold)
    assert p == pytest.approx(0.5)
    assert r == pytest.approx(0.5)
    assert f1 == pytest.approx(0.5)


def test_citation_empty_gold_and_pred() -> None:
    assert precision_recall([], []) == (1.0, 1.0, 1.0)


def test_citation_spurious_when_gold_empty() -> None:
    p, r, f1 = precision_recall([_src(chunk_id="ghost")], [])
    assert p == 0.0
    assert r == 1.0
    assert f1 == 0.0


def test_citation_miss_when_pred_empty() -> None:
    p, r, f1 = precision_recall([], [_src(chunk_id="a")])
    assert (p, r, f1) == (0.0, 0.0, 0.0)


def test_grounding_supported_vs_unsupported() -> None:
    context = ["Atlas-2 must stop within 0.4 seconds of obstacle detection."]
    supported = grounding_score(
        "The Atlas-2 must stop within 0.4 seconds of obstacle detection.",
        context,
    )
    invented = grounding_score("The CEO lives on Mars and collects stamps.", context)
    assert supported == 1.0
    assert invented == 0.0


def test_grounding_refusal_is_vacuously_grounded() -> None:
    assert grounding_score("I don't know. Insufficient evidence.", []) == 1.0
    assert grounding_score("", []) == 1.0


def test_grounding_invented_claim_against_empty_context() -> None:
    assert grounding_score("Revenue was nine billion dollars.", []) == 0.0


def test_refusal_detection() -> None:
    assert is_refusal_text("I don't know. The sources do not contain that figure.")
    assert is_refusal_text("Insufficient evidence is available.")
    assert is_refusal_text("I could not find any relevant sources to answer this question.")
    assert not is_refusal_text("Helios Q3 2025 revenue was $47.2 million.")


def test_source_marker_resolution_matches_clara() -> None:
    chunks = [
        _chunk(id="chk-a", document_id="d1", filename="a.md", chunk_index=0, text="alpha"),
        _chunk(id="chk-b", document_id="d2", filename="b.md", chunk_index=0, text="beta"),
    ]
    cites = citations_from_source_markers("Use [Source 2] and ignore [Source 9].", chunks)
    assert len(cites) == 1
    assert cites[0].chunk_id == "chk-b"


def test_score_prediction_refusal_accuracy() -> None:
    item = GoldItem.from_dict(
        {
            "id": "u1",
            "kind": "unanswerable",
            "question": "Who is the CEO?",
            "must_refuse": True,
            "gold_sources": [],
        }
    )
    good = Prediction.from_dict({"id": "u1", "answer": "I don't know.", "citations": []})
    bad = Prediction.from_dict({"id": "u1", "answer": "Ada Lovelace is the CEO.", "citations": []})
    assert score_prediction(item, good).refusal_correct is True
    assert score_prediction(item, bad).refusal_correct is False


def test_citation_hallucination_flagged() -> None:
    retrieved = [
        _chunk(
            id="chk-q3-2",
            document_id="doc-q3",
            filename="q3-earnings.md",
            chunk_index=2,
            text="Q4 guidance $51 to $54 million.",
        )
    ]
    pred = [
        _src(
            chunk_id="chk-cook-0",
            document_id="doc-cookbook",
            filename="sourdough-notes.md",
            chunk_index=0,
        )
    ]
    assert hallucination_rate(pred, retrieved) == 1.0
    assert hallucination_rate([_src(chunk_id="chk-q3-2", document_id="doc-q3")], retrieved) == 0.0


def test_retrieval_hit_at_k_math() -> None:
    gold = [_src(chunk_id="chk-a"), _src(chunk_id="chk-b")]
    hit, recall = retrieval_hit_at_k(["chk-a", "chk-z"], gold, k=5)
    assert hit == 1.0
    assert recall == pytest.approx(0.5)
    miss, miss_r = retrieval_hit_at_k(["chk-z"], gold, k=5)
    assert miss == 0.0
    assert miss_r == 0.0
    empty_hit, empty_r = retrieval_hit_at_k(["chk-z"], [], k=5)
    assert empty_hit == 1.0
    assert empty_r == 1.0


def test_macro_average_math() -> None:
    item = GoldItem.from_dict(
        {
            "id": "x",
            "kind": "answerable",
            "question": "q",
            "must_refuse": False,
            "gold_sources": [{"chunk_id": "a"}],
        }
    )
    perfect = score_prediction(
        item,
        Prediction.from_dict(
            {
                "id": "x",
                "answer": "supported token overlap answer about widgets.",
                "citations": [{"chunk_id": "a", "document_id": "d", "filename": "f.md"}],
                "retrieved": [
                    {
                        "id": "a",
                        "document_id": "d",
                        "filename": "f.md",
                        "chunk_index": 0,
                        "text": "supported token overlap answer about widgets.",
                    }
                ],
            }
        ),
    )
    suite = aggregate([perfect, perfect])
    assert suite.n == 2
    assert suite.grounding == 1.0
    assert suite.citation_precision == 1.0
    assert suite.citation_recall == 1.0
    assert suite.citation_f1 == 1.0
    assert suite.refusal_accuracy == 1.0


def test_offline_scorer_on_bundled_fixtures() -> None:
    gold = load_gold()
    preds = load_predictions()
    corpus = load_corpus()
    suite = score_dataset(gold, preds, k=5, corpus=corpus)

    assert suite.n == 16
    assert {i.id for i in gold} == {p.id for p in preds}

    by_id = {s.id: s for s in suite.items}

    # Perfect single-hop + inline [Source N] resolution (ans-005).
    for item_id in ("ans-001", "ans-002", "ans-003", "ans-004", "ans-005", "ans-007"):
        row = by_id[item_id]
        assert row.citation_precision == 1.0
        assert row.citation_recall == 1.0
        assert row.refusal_correct is True
        assert row.grounding == 1.0

    # Citation hallucination: grounded answer, cite a file that was not retrieved.
    trap = by_id["ans-006"]
    assert trap.citation_hallucination_rate == 1.0
    assert trap.citation_precision == 0.0
    assert trap.citation_recall == 0.0
    assert trap.grounding == 1.0
    assert trap.retrieval_hit_at_k == 1.0

    # Multi-hop partial cite: one of two gold sources.
    hop = by_id["hop-001"]
    assert hop.citation_precision == 1.0
    assert hop.citation_recall == pytest.approx(0.5)
    assert hop.citation_f1 == pytest.approx(2 / 3, abs=1e-3)

    # Unanswerable refusals vs the invented Atlas-3 price.
    assert by_id["unk-001"].refusal_correct is True
    assert by_id["unk-002"].refusal_correct is True
    assert by_id["unk-003"].refusal_correct is False
    assert by_id["unk-004"].refusal_correct is True
    assert by_id["part-001"].refusal_correct is True
    assert by_id["part-002"].refusal_correct is False

    # 16 items: 10 should answer, 6 should refuse. 2 refusal misses → 14/16.
    assert suite.refusal_accuracy == pytest.approx(14 / 16, abs=1e-3)
    assert suite.refusal_accuracy_unanswerable == pytest.approx(4 / 6, abs=1e-3)
    assert suite.citation_hallucination_rate == pytest.approx(1 / 16, abs=1e-3)
    assert suite.retrieval_hit_at_k == 1.0


def test_lexical_retrieval_hits_gold_sources() -> None:
    corpus = load_corpus()
    gold = {item.id: item for item in load_gold()}

    q3 = retrieve_lexical(gold["ans-001"].question, corpus, top_k=5)
    assert any(c.id == "chk-q3-0" for c in q3)

    safety = retrieve_lexical(gold["ans-003"].question, corpus, top_k=5)
    assert any(c.id == "chk-safety-0" for c in safety)

    vendor = retrieve_lexical(gold["ans-004"].question, corpus, top_k=5)
    assert any(c.id == "chk-vendor-0" for c in vendor)

    # Queries with no corpus overlap return no hits.
    assert LexicalIndex(corpus).search("xyzzy qwx plugh", top_k=3) == []


def test_stub_generator_refuses_zero_overlap() -> None:
    corpus = load_corpus()
    pred = generate_stub(
        "zero",
        "xyzzy qwx plugh fnord",
        corpus[:3],
        index_chunks=corpus,
    )
    assert pred.refused is True
    assert "don't know" in pred.answer.lower() or "insufficient" in pred.answer.lower()


def test_stub_generator_answers_from_retrieved() -> None:
    corpus = load_corpus()
    gold = {item.id: item for item in load_gold()}
    retrieved = retrieve_lexical(gold["ans-001"].question, corpus, top_k=5)
    pred = generate_stub(
        "ans-001", gold["ans-001"].question, retrieved, index_chunks=corpus
    )
    assert pred.refused is False
    assert pred.citations
    assert "[Source" in pred.answer
    assert "47.2" in pred.answer


def test_stub_generator_empty_retrieve_refuses() -> None:
    pred = generate_stub("x", "anything", [])
    assert pred.refused is True
    assert pred.answer == REFUSAL_ANSWER


def test_live_runner_and_table() -> None:
    gold = load_gold()
    corpus = load_corpus()
    suite = run_live(gold, corpus, k=5, retriever="lexical")
    table = format_table(suite)
    assert "MACRO" in table
    assert "ans-001" in table
    assert suite.n == 16
    by_id = {s.id: s for s in suite.items}
    # Stub answers from retrieved context; retrieval hit-rate is the live signal.
    assert by_id["ans-001"].refused is False
    assert by_id["ans-001"].retrieval_hit_at_k == 1.0
    assert suite.retrieval_hit_at_k == 1.0


def test_offline_runner_matches_scorer() -> None:
    gold = load_gold()
    preds = load_predictions()
    corpus = load_corpus()
    suite = run_offline(gold, preds, corpus, k=5)
    assert suite.n == 16
    assert "citation_precision" in suite.to_dict()


def test_eval_modules_do_not_import_torch(monkeypatch: pytest.MonkeyPatch) -> None:
    import builtins
    import sys

    original = builtins.__import__

    def guarded(name: str, *args: object, **kwargs: object) -> object:
        root = name.split(".", 1)[0]
        if root in {"torch", "transformers", "sentence_transformers"}:
            raise ImportError(f"blocked {name}")
        return original(name, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(builtins, "__import__", guarded)
    for mod in list(sys.modules):
        if mod == "torch" or mod.startswith("eval"):
            sys.modules.pop(mod, None)

    import eval.metrics as metrics_mod
    import eval.scorer as scorer_mod

    assert scorer_mod.score_prediction is not None
    assert metrics_mod.grounding_score is not None


def test_clara_hash_retriever_ranks_without_torch() -> None:
    """CLaRa Core TF-IDF path, if importable, must not need the Pro pack."""
    from eval.retrieval import retrieve_clara_hash

    corpus = load_corpus()
    result = retrieve_clara_hash("Helios Robotics Q3 2025 revenue", corpus, top_k=3)
    if result is None:
        pytest.skip("clara.compressor unavailable")
    assert result
    assert {c.id for c in result} <= {c.id for c in corpus}
    assert any(c.id == "chk-q3-0" for c in result)


def test_cli_json_roundtrip(capsys: pytest.CaptureFixture[str]) -> None:
    from eval.runner import main

    code = main(["--mode", "offline", "--json"])
    assert code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["n"] == 16
    assert "items" in payload
    assert payload["refusal_accuracy"] == pytest.approx(14 / 16, abs=1e-3)
