"""Phase 1 campaign orchestration: blocking, profiles, order, supervision, path refusal."""

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


camp = load_script("run_phase1")
SCRIPT = ROOT / "scripts/run_phase1.py"
# Keys `ModelProfile.read` (Sources/RealAdapterSupport/ModelProfile.swift) requires, no more, no less.
SWIFT_PROFILE_KEYS = {"profile_version", "adapter_id", "role", "framework", "model", "compute_units", "settings",
                      "output", "notes"}


def test_order_alternates_frameworks_per_repetition_diarization_first():
    order = camp.measured_order(3)
    assert [(rep, role, tuple(fw)) for rep, role, fw in order] == [
        (1, "diarization", ("fluid", "speech")), (1, "asr", ("fluid", "speech")),
        (2, "diarization", ("speech", "fluid")), (2, "asr", ("speech", "fluid")),
        (3, "diarization", ("fluid", "speech")), (3, "asr", ("fluid", "speech"))]


def test_timeout_is_three_times_media_plus_ten_minutes():
    assert camp.run_timeout_s(1200 * 16000) == 3 * 1200 + 600
    assert camp.run_timeout_s(16000) == 603
    assert camp.run_timeout_s(0) == 600


def model_entry(tmp_path: Path, **overrides) -> dict:
    root = tmp_path / "models"
    (root / "pkg.mlpackage/Data").mkdir(parents=True)
    (root / "pkg.mlpackage/Data/weights.bin").write_bytes(b"w" * 10)
    (root / "pkg.mlpackage/Manifest.json").write_text("{}")
    entry = {"root": str(root), "repository": "org/model", "revision": "a" * 40, "load_path": "pkg.mlpackage",
             "precision": "fp16", "licenses": ["NVIDIA Open Model License", "conversion terms"],
             "license_acceptance": {"accepted": True, "evidence": "owner statement 2026-10-21"}}
    entry.update(overrides)
    return entry


@pytest.mark.parametrize("override,reason", [
    ({"license_acceptance": {"accepted": False}}, "acceptance"),
    ({"revision": "main"}, "immutable"),
    ({"load_path": "absent.mlpackage"}, "absent"),
])
def test_missing_permissions_or_files_block_the_row(tmp_path: Path, override: dict, reason: str):
    row = camp.MATRIX[0]
    entry, problem = camp.model_prerequisites(row, {"models": {row["adapter_id"]: model_entry(tmp_path, **override)}})
    assert entry is None and reason in problem
    assert camp.model_prerequisites(row, {"models": {}})[1].startswith("inputs supply no model entry")


def test_profile_lists_every_file_with_hashes_and_matches_the_swift_reader(tmp_path: Path):
    row = camp.MATRIX[0]
    entry, problem = camp.model_prerequisites(row, {"models": {row["adapter_id"]: model_entry(tmp_path)}})
    assert problem is None
    data = camp.build_profile(row, entry, "b" * 64)
    profile = json.loads(data)
    assert set(profile) == SWIFT_PROFILE_KEYS
    assert [f["path"] for f in profile["model"]["files"]] == ["pkg.mlpackage/Data/weights.bin", "pkg.mlpackage/Manifest.json"]
    assert profile["output"]["eos_tail_tolerance_samples"] == camp.TAIL_TOLERANCE and profile["compute_units"] == "all"
    assert camp.build_profile(row, entry, "b" * 64) == data, "profile bytes are deterministic"
    asr = camp.build_profile(camp.MATRIX[2], entry, None)
    assert json.loads(asr)["output"]["eos_tail_tolerance_samples"] is None


def test_generated_config_is_accepted_by_the_strict_loader(tmp_path: Path, voicebench: Path):
    """The mock form of the generated YAML runs end to end (same template as the real rows)."""
    config = tmp_path / "c.yaml"
    config.write_text(camp.config_yaml(None, None, ROOT / "datasets/manifests/synthetic.json", "two-speaker-en",
                                       mode="step", mock=True))
    result = subprocess.run([str(voicebench), "run", "--config", str(config), "--runs-dir", str(tmp_path / "runs"),
                             "--run-id", "gen"], capture_output=True, text=True, timeout=600, check=False)
    assert result.returncode == 0, result.stderr
    real = camp.config_yaml(camp.MATRIX[0], "p1:" + "c" * 64, Path("/m.json"), "item")
    assert "diarization: {id: fluid-sortformer-v21-lowctx" in real and "asr: {id: passive-asr" in real
    assert "references: optional" in real and "mode: realtime" in real and "delay_ms: 0" in real


def test_supervisor_stops_its_own_process_on_timeout_and_keeps_the_log(tmp_path: Path):
    result = camp.supervised([sys.executable, "-c", "import time; print('started', flush=True); time.sleep(30)"],
                             {"PATH": "/usr/bin:/bin"}, timeout_s=1, log=tmp_path / "run.log", poll_s=0.2)
    assert result["stopped_by_supervisor"] == "timeout" and result["exit_code"] != 0
    assert "started" in (tmp_path / "run.log").read_text()
    with pytest.raises(FileExistsError):
        camp.supervised([sys.executable, "-c", "pass"], {}, 10, tmp_path / "run.log")


def test_ledger_is_append_only(tmp_path: Path):
    ledger = camp.Ledger(tmp_path / "ledger.jsonl")
    ledger.append({"kind": "measured", "status": "failed"})
    ledger.append({"kind": "measured", "status": "valid"})
    assert [json.loads(line)["status"] for line in (tmp_path / "ledger.jsonl").read_text().splitlines()] == ["failed", "valid"]


def test_campaign_without_inputs_is_not_run_and_refuses_existing_output(tmp_path: Path, voicebench: Path):
    out = tmp_path / "campaign"
    argv = [sys.executable, str(SCRIPT), "campaign", "--inputs", str(tmp_path / "absent.json"), "--datasets",
            str(tmp_path / "datasets"), "--voicebench", str(voicebench), "--out", str(out)]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=120, check=False)
    summary = json.loads((out / "campaign-summary.json").read_text())
    assert result.returncode == 3 and summary["status"] == "NOT_RUN" and set(summary["blocked"]) == {"D1", "D2", "A1", "A2"}
    again = subprocess.run(argv, capture_output=True, text=True, timeout=120, check=False)
    assert again.returncode != 0 and "File exists" in again.stderr


def test_campaign_blocks_rows_with_missing_frameworks_data_or_models(tmp_path: Path, voicebench: Path):
    inputs = tmp_path / "inputs.json"
    inputs.write_text(json.dumps({"inputs_version": 1, "models": {}, "datasets": {}}))
    out = tmp_path / "campaign"
    result = subprocess.run([sys.executable, str(SCRIPT), "campaign", "--inputs", str(inputs), "--datasets",
                             str(tmp_path / "no-datasets"), "--voicebench", str(voicebench), "--out", str(out)],
                            capture_output=True, text=True, timeout=300, check=False)
    assert result.returncode == 3, result.stderr
    matrix = json.loads((out / "matrix.json").read_text())
    assert matrix["rows"] == {} and set(matrix["blocked"]) == {"D1", "D2", "A1", "A2"}
    assert all("AMI dataset not ready" in reason for reason in matrix["blocked"].values())
    controls = json.loads((out / "sandbox-controls.json").read_text())
    assert controls["denial_enforced"] is True, controls
    entries = [json.loads(line) for line in (out / "ledger.jsonl").read_text().splitlines()]
    assert {e["row"] for e in entries if e["status"] == "blocked"} == {"D1", "D2", "A1", "A2"}
