"""Comparison compatibility (V17): field-level reasons, no ranking unless comparable."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from conftest import PROJECT_ROOT
from phase0_analysis.compare import compare

SCHEMAS = PROJECT_ROOT / "schemas/v1"


def blocking(report: dict) -> set[str]:
    return {r["field"] for r in report["reasons"] if r["effect"] == "blocks_ranking"}


def test_identical_settings_are_accuracy_comparable_and_ranked(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["step-b"]], "accuracy", SCHEMAS, False)
    assert report["compatible"] and blocking(report) == set()
    assert report["ranking"] == ["step-a", "step-b"], "ties are broken by run ID, deterministically"


def test_different_sources_block_with_precise_reasons(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["hindi"]], "accuracy", SCHEMAS, False)
    assert not report["compatible"] and report["ranking"] is None
    assert {"source_id", "inputs.audio_sha256", "inputs.reference_sha256", "languages"} <= blocking(report)


def test_override_never_ranks(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["hindi"]], "accuracy", SCHEMAS, True)
    assert report["allow_noncomparable"] and not report["compatible"] and report["ranking"] is None
    assert len(report["rows"]) == 8, "side-by-side rows are still emitted"


def test_seed_difference_is_disclosed_not_blocking_for_accuracy(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["seed"]], "accuracy", SCHEMAS, False)
    assert report["compatible"]
    assert any(r["field"] == "seed" and r["effect"] == "disclosed" for r in report["reasons"])


def test_step_mode_cannot_be_latency_ranked(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["step-b"]], "latency", SCHEMAS, False)
    assert "replay.mode" in blocking(report) and report["ranking"] is None


def test_lossy_run_is_excluded_from_accuracy_ranking(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["drop"]], "accuracy", SCHEMAS, False)
    assert "disclosure.data_loss" in blocking(report)


def test_endpoint_correction_is_identified(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["endpoint"]], "accuracy", SCHEMAS, True)
    assert "conversion.endpoint_status" in blocking(report)
    assert any(r["field"] == "disclosure.endpoint_correction" for r in report["reasons"])


def test_tampered_or_unsealed_run_blocks(sealed: dict[str, Path], tmp_path: Path) -> None:
    corrupt = tmp_path / "corrupt"
    shutil.copytree(sealed["step-b"], corrupt)
    metrics = json.loads((corrupt / "metrics.json").read_text())
    metrics["accuracy"]["wer"]["value"] = 0.0
    (corrupt / "metrics.json").write_text(json.dumps(metrics))
    report = compare([sealed["step-a"], corrupt], "accuracy", SCHEMAS, False)
    assert "validation.sealed" in blocking(report)
    status = json.loads((corrupt / "status.json").read_text())
    status.update(state="failed", failure={"category": "runtime", "stage": "running", "message": "x"}, artifacts=None)
    (corrupt / "status.json").write_text(json.dumps(status))
    assert "status.state" in blocking(compare([sealed["step-a"], corrupt], "accuracy", SCHEMAS, False))


def test_incomplete_measurements_are_reported(sealed: dict[str, Path]) -> None:
    report = compare([sealed["step-a"], sealed["step-b"]], "resources", SCHEMAS, True)
    assert any(r["field"] == "incomplete_measurement.resources.gpu_utilization" for r in report["reasons"])
