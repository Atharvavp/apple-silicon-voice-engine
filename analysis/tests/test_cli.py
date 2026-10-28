"""CLI behavior through the built binary (V06/V16): overrides freeze exactly,
rescoring never touches the initial metrics, validation surfaces corrections."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

from conftest import PROJECT_ROOT, sealed_run


def vb(voicebench: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(voicebench), *args], capture_output=True, text=True, timeout=600, cwd=PROJECT_ROOT,
                          check=False)


def test_overrides_are_validated_then_frozen(voicebench: Path, tmp_path: Path) -> None:
    run = sealed_run(voicebench, "mock-step.yaml", tmp_path, "accel", "--mode", "accelerated", "--speed", "2.5")
    config = json.loads((run / "config.json").read_text())
    assert config["settings"]["replay"]["mode"] == "accelerated"
    assert config["replay_resolved"]["speed"] == {"num": 5, "den": 2}
    bad = vb(voicebench, "run", "--config", "configs/mock-accelerated.yaml", "--runs-dir", str(tmp_path),
             "--run-id", "too-fast", "--speed", "100.5")
    assert bad.returncode == 2 and "100" in bad.stderr
    assert not (tmp_path / "too-fast").exists()


def test_rescore_and_revalidation_leave_sealed_files_untouched(voicebench: Path, sealed: dict[str, Path]) -> None:
    run = sealed["step-b"]
    before = {p.name: p.read_bytes() for p in run.iterdir() if p.is_file()}
    assert vb(voicebench, "validate", "--run", str(run), "--rescore", "--analysis-id", "cli-test").returncode == 0
    assert vb(voicebench, "validate", "--run", str(run)).returncode == 0
    after = {p.name: p.read_bytes() for p in run.iterdir() if p.is_file()}
    assert before == after
    derived = json.loads((run / "derived/cli-test/metrics.json").read_text())
    assert derived["analysis_id"] == "cli-test"
    assert derived["accuracy"] == json.loads((run / "metrics.json").read_text())["accuracy"]


def test_validation_discloses_endpoint_correction(voicebench: Path, sealed: dict[str, Path]) -> None:
    ok = vb(voicebench, "validate", "--run", str(sealed["endpoint"]))
    assert ok.returncode == 0 and "endpoint_correction" in ok.stderr
    strict = vb(voicebench, "validate", "--run", str(sealed["endpoint"]), "--require-exact-endpoints")
    assert strict.returncode == 9 and "conversion:strict_endpoints" in strict.stderr


def test_suite_never_reports_an_unearned_pass(voicebench: Path, tmp_path: Path) -> None:
    result = vb(voicebench, "validate", "--suite", "gate-a", "--evidence-dir", str(tmp_path))
    assert result.returncode != 0


def test_sigint_cancels_a_running_experiment(voicebench: Path, tmp_path: Path) -> None:
    """A real SIGINT reaches the dispatch-source handler and ends the run `cancelled` (exit 130)."""
    import signal
    import time

    process = subprocess.Popen([str(voicebench), "run", "--config", str(PROJECT_ROOT / "configs/mock-realtime.yaml"),
                                "--runs-dir", str(tmp_path), "--run-id", "sigint"], cwd=PROJECT_ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    status = tmp_path / "sigint/status.json"
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if status.exists() and json.loads(status.read_text())["state"] == "running":
            break
        time.sleep(0.05)
    time.sleep(0.5)
    process.send_signal(signal.SIGINT)
    _, stderr = process.communicate(timeout=60)
    assert process.returncode == 130, stderr.decode()
    final = json.loads(status.read_text())
    assert final["state"] == "cancelled" and final["failure"]["category"] == "cancelled"
    lines = (tmp_path / "sigint/events.jsonl.partial").read_bytes().splitlines()
    assert json.loads(lines[-1])["type"] == "experiment.cancelled"
