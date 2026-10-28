"""Phase 1 report: eligibility rejection, summaries without pooled percentiles, status rules."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


rep = load_script("report_phase1")
MATRIX = {"rows": {"D1": {"adapter_id": "fluid-sortformer-v21-lowctx", "role": "diarization", "framework": "fluid",
                          "revision": "p1:" + "a" * 64, "binary_sha256": "x"}}, "blocked": {}}


@pytest.fixture(scope="module")
def mock_run(voicebench: Path, tmp_path_factory: pytest.TempPathFactory) -> Path:
    runs = tmp_path_factory.mktemp("runs")
    result = subprocess.run([str(voicebench), "run", "--config", str(ROOT / "configs/mock-step.yaml"), "--runs-dir",
                             str(runs), "--run-id", "mock"], capture_output=True, timeout=600, check=False)
    assert result.returncode == 0, result.stderr
    return runs / "mock"


def test_mock_or_mismatched_runs_are_never_eligible(mock_run: Path):
    reasons, facts = rep.eligibility(mock_run, "D1", MATRIX, {"crop": {"sha256": "0" * 64}, "item_id": "x"},
                                     {"validate_exit_code": 0})
    text = "; ".join(reasons)
    assert "mock adapters" in text and "differs from the frozen" in text and "not passive" in text
    assert "audio/item differs" in text and "replay policy" in text
    row = rep.run_row(mock_run, "D1", {"run_id": "mock", "repetition": 1, "status": "valid"}, facts, reasons)
    assert row["eligible"] is False and row["der"] is not None  # values kept for the record, never ranked


def test_unsealed_or_unvalidated_runs_are_rejected(tmp_path: Path, mock_run: Path):
    reasons, _ = rep.eligibility(tmp_path, "D1", MATRIX, {}, {"validate_exit_code": 0})
    assert reasons and "not completed" in reasons[0]
    reasons, _ = rep.eligibility(mock_run, "D1", MATRIX, {}, {"validate_exit_code": 9})
    assert any("validate --run exit 9" in r for r in reasons)


def row(row_id: str, eligible: bool, **values) -> dict:
    return {"row": row_id, "eligible": eligible, **values}


def test_summary_is_median_min_max_of_eligible_runs_only():
    runs = [row("A1", True, wer=0.30), row("A1", True, wer=0.10), row("A1", True, wer=0.20), row("A1", False, wer=0.0)]
    summary = rep.summarize(runs)
    assert summary["A1"]["valid_n"] == 3 and summary["A1"]["attempts"] == 4
    assert summary["A1"]["wer"] == {"median": 0.20, "min": 0.10, "max": 0.30, "n": 3}
    assert summary["D1"]["valid_n"] == 0 and summary["D1"]["der"] is None


def test_status_rules():
    full = rep.summarize([row(r, True, wer=0.1) for r in rep.ROWS for _ in range(3)])
    assert rep.overall_status(full, {"comparison": {"status": "pass"}}) == "COMPLETE"
    assert rep.overall_status(full, {"comparison": {"status": "fail"}}) == "INVALID"
    partial = rep.summarize([row(r, True) for r in rep.ROWS for _ in range(2)])
    assert rep.overall_status(partial, None) == "PARTIAL"
    assert rep.overall_status(rep.summarize([]), None) == "NOT_RUN"


def test_pairs_are_best_practical_never_matched_model():
    summary = rep.summarize([row(r, True) for r in rep.ROWS])
    pairs = rep.classify(summary, {"rows": {}})
    assert {p["classification"] for p in pairs.values()} == {"best_practical"}
    assert all(p["matched_model_evidence"] is None for p in pairs.values())
    one_sided = rep.classify(rep.summarize([row("D1", True)]), {"rows": {}})
    assert one_sided["diarization"]["classification"] == "not_comparable"


def test_empty_campaign_reports_not_run_and_withholds_the_linkedin_draft(tmp_path: Path):
    campaign = tmp_path / "campaign"
    campaign.mkdir()
    (campaign / "matrix.json").write_text(json.dumps({"rows": {}, "blocked": {"D1": "no inputs"}}))
    out = tmp_path / "report"
    argv = [sys.executable, str(ROOT / "scripts/report_phase1.py"), "--campaign", str(campaign), "--datasets",
            str(tmp_path), "--out", str(out)]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=120, check=False)
    assert result.returncode == 0, result.stderr
    text = (out / "PHASE_1_RESULTS.md").read_text()
    assert "Status: **NOT_RUN**" in text and "blocked: no inputs" in text and "Withheld" in text
    assert not list(out.glob("*.png")), "no plots without eligible data"
    again = subprocess.run(argv, capture_output=True, text=True, timeout=120, check=False)
    assert again.returncode != 0
