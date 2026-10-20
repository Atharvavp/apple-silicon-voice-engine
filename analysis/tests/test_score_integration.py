"""End-to-end scoring of genuine runtime-stage runs (V08/V09/V18 foundations)."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import PROJECT_ROOT, runtime_stage
from phase0_analysis.schemas import SchemaStore
from phase0_analysis.score import score_run
from phase0_analysis.trace import project_metrics

SCHEMAS = PROJECT_ROOT / "schemas/v1"
GOLDEN = json.loads((PROJECT_ROOT / "testdata/goldens/asr.json").read_text(encoding="utf-8"))["pipeline_items"]
CONFIGS = {"two-speaker-en": "mock-step.yaml", "two-speaker-hi": "mock-step-hi.yaml",
           "endpoint-trim-en": "mock-step-endpoint.yaml"}


@pytest.fixture(scope="module")
def item_runs(voicebench: Path, tmp_path_factory: pytest.TempPathFactory) -> dict[str, Path]:
    runs = tmp_path_factory.mktemp("items")
    return {item: runtime_stage(voicebench, PROJECT_ROOT / "configs" / config, runs, item)
            for item, config in CONFIGS.items()}


@pytest.mark.parametrize("item", sorted(CONFIGS))
def test_pipeline_scores_match_hand_derivations(item: str, item_runs: dict[str, Path]) -> None:
    metrics = score_run(item_runs[item], SCHEMAS)
    assert SchemaStore(SCHEMAS).issues("metrics", metrics) == []
    expected = GOLDEN[item]
    accuracy = metrics["accuracy"]
    for key in ("wer", "cer"):
        components = accuracy[key]["components"]
        assert (components["substitutions"], components["deletions"], components["insertions"],
                components["reference_units"]) == tuple(expected[key][k] for k in ("S", "D", "I", "N"))
        assert accuracy[key]["value"] == pytest.approx(expected[key]["value"], abs=1e-9)
    assert accuracy["der"]["value"] == pytest.approx(expected["der"], abs=1e-9)
    assert accuracy["jer"]["value"] == pytest.approx(expected["jer"], abs=1e-9)
    assert metrics["mock"] is True, "mock scores are labelled as such"


def test_endpoint_correction_is_carried_into_metrics(item_runs: dict[str, Path]) -> None:
    metrics = score_run(item_runs["endpoint-trim-en"], SCHEMAS)
    corrected = metrics["data_integrity"]["endpoint_corrected_frames"]
    assert corrected["value"] == 1 and corrected["components"]["endpoint_status"] == "trimmed_one_frame"


def test_scoring_is_deterministic_for_the_accuracy_projection(item_runs: dict[str, Path]) -> None:
    a = project_metrics(score_run(item_runs["two-speaker-en"], SCHEMAS))
    b = project_metrics(score_run(item_runs["two-speaker-en"], SCHEMAS))
    assert a == b


def test_tampered_prefix_is_refused(item_runs: dict[str, Path], tmp_path: Path) -> None:
    run = tmp_path / "run"
    shutil.copytree(item_runs["two-speaker-en"], run)
    trace = run / "events.jsonl.partial"
    trace.write_bytes(trace.read_bytes().replace(b'"hello world"', b'"hello_world"'))
    with pytest.raises(ValueError, match="runtime prefix"):
        score_run(run, SCHEMAS)


def test_score_cli_writes_once_and_never_overwrites(item_runs: dict[str, Path], tmp_path: Path) -> None:
    run = tmp_path / "run"
    shutil.copytree(item_runs["two-speaker-hi"], run)
    command = [sys.executable, "-m", "phase0_analysis", "score", "--run", str(run), "--schemas", str(SCHEMAS)]
    first = subprocess.run(command, capture_output=True, text=True, cwd=PROJECT_ROOT, check=False)
    assert first.returncode == 0, first.stderr
    assert json.loads((run / "validation.json").read_text())["stage"] == "initial"
    before = (run / "metrics.json").read_bytes()
    second = subprocess.run(command, capture_output=True, text=True, cwd=PROJECT_ROOT, check=False)
    assert second.returncode != 0, "an existing metrics.json is never replaced"
    assert (run / "metrics.json").read_bytes() == before
