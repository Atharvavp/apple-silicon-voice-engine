"""Artifact validation (V13-V15): genuine runs pass; tampered, truncated or
incomplete runs fail; corrections and losses are disclosed."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import PROJECT_ROOT, runtime_stage
from phase0_analysis.validate import validate_run

SCHEMAS = PROJECT_ROOT / "schemas/v1"


def failed(report: dict) -> set[str]:
    return {c["check_id"] for c in report["checks"] if c["status"] == "fail"}


def test_genuine_runtime_stage_passes(step_run: Path) -> None:
    report = validate_run(step_run, SCHEMAS, "runtime")
    assert report["status"] == "pass", failed(report)
    assert report["disclosures"] == []


def test_unsealed_run_cannot_pass_as_sealed(step_run: Path) -> None:
    report = validate_run(step_run, SCHEMAS, "sealed")
    assert report["status"] == "fail"
    assert "events:present" in failed(report) or "status:completed" in failed(report)


def test_initial_stage_requires_metrics(step_run: Path) -> None:
    assert "schema:metrics.json" in failed(validate_run(step_run, SCHEMAS, "initial"))


def test_tampered_trace_byte_is_detected(step_copy: Path) -> None:
    path = step_copy / "events.jsonl.partial"
    data = bytearray(path.read_bytes())
    index = data.index(b'"text":"hello world"') + len(b'"text":"hello')
    data[index:index + 1] = b"_"
    path.write_bytes(bytes(data))
    assert {"events:prefix_descriptor", "predictions:rebuild"} <= failed(validate_run(step_copy, SCHEMAS, "runtime"))


def test_edited_predictions_are_detected(step_copy: Path) -> None:
    path = step_copy / "predictions.json"
    predictions = json.loads(path.read_text())
    predictions["transcript"][0]["text"] = "hello there"
    path.write_text(json.dumps(predictions, indent=2, ensure_ascii=False))
    assert "predictions:rebuild" in failed(validate_run(step_copy, SCHEMAS, "runtime"))


def test_edited_reference_copy_is_detected(step_copy: Path) -> None:
    path = step_copy / "references/transcript.json"
    path.write_text(path.read_text().replace("Hello, WORLD!", "Hello, world!"))
    assert "inputs:reference_copies" in failed(validate_run(step_copy, SCHEMAS, "runtime"))


def test_terminal_event_in_runtime_prefix_is_rejected(step_copy: Path) -> None:
    path = step_copy / "events.jsonl.partial"
    lines = path.read_bytes().splitlines(keepends=True)
    extra = json.loads(lines[-1])
    extra.update(sequence=len(lines), type="experiment.completed", event_id="x/runner/experiment.completed/0",
                 payload={"artifacts": []})
    path.write_bytes(b"".join(lines) + json.dumps(extra).encode() + b"\n")
    assert "events:no_terminal_yet" in failed(validate_run(step_copy, SCHEMAS, "runtime"))


@pytest.fixture(scope="module")
def endpoint_run(voicebench: Path, tmp_path_factory: pytest.TempPathFactory) -> Path:
    return runtime_stage(voicebench, PROJECT_ROOT / "configs/mock-step-endpoint.yaml", tmp_path_factory.mktemp("e"), "ep")


def test_endpoint_correction_is_disclosed_and_strict_enforcement_fails(endpoint_run: Path) -> None:
    report = validate_run(endpoint_run, SCHEMAS, "runtime")
    assert report["status"] == "pass", failed(report)
    assert [d["code"] for d in report["disclosures"]] == ["endpoint_correction"]
    assert "trimmed_one_frame" in report["disclosures"][0]["message"]
    strict = validate_run(endpoint_run, SCHEMAS, "runtime", require_exact_endpoints=True)
    assert failed(strict) == {"conversion:strict_endpoints"}


def test_lossy_run_discloses_exact_dropped_ranges(voicebench: Path, tmp_path: Path) -> None:
    run = runtime_stage(voicebench, PROJECT_ROOT / "configs/mock-slow-drop.yaml", tmp_path, "drop")
    report = validate_run(run, SCHEMAS, "runtime")
    assert report["status"] == "pass", failed(report)
    summary = json.loads((run / "runtime_summary.json").read_text())
    assert summary["data_loss"] is True and summary["coverage"]["dropped_samples"] > 0
    assert [d["code"] for d in report["disclosures"]] == ["data_loss"]
    dropped = sum(r["end_sample"] - r["start_sample"] for r in summary["coverage"]["dropped_ranges"])
    assert dropped == summary["coverage"]["dropped_samples"]
    predictions = json.loads((run / "predictions.json").read_text())
    assert predictions["coverage"]["dropped_ranges"] == summary["coverage"]["dropped_ranges"]
