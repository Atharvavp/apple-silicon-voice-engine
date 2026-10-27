"""Publication entrypoints: setup refusal, smoke accounting and preservation of existing output.

Needs macOS (setup.sh/smoke.sh check the host) and a built CLI for the smoke-check cases; not part of
the Linux portable subset.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import PROJECT_ROOT, sealed_run

SCRIPTS = PROJECT_ROOT / "scripts"


def _tree(path: Path) -> dict[str, str]:
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(path.rglob("*")) if p.is_file()}


def _populated(tmp_path: Path) -> tuple[Path, dict[str, str]]:
    out = tmp_path / "existing"
    (out / "nested").mkdir(parents=True)
    (out / "SENTINEL").write_text("owner evidence\n")
    (out / "nested" / "keep.json").write_text("{}\n")
    return out, _tree(out)


def _fake_python(tmp_path: Path, name: str, version: str) -> Path:
    path = tmp_path / name
    path.write_text(f"#!/bin/sh\necho {version}\n")
    path.chmod(0o755)
    return path


# --- existing output is refused, never deleted ---------------------------------------------------

REFUSAL_CASES = {
    "e2e": lambda out: [sys.executable, str(SCRIPTS / "e2e.py"), "--voicebench", "/usr/bin/true", "--out", str(out)],
    "determinism": lambda out: [sys.executable, str(SCRIPTS / "determinism.py"), "--voicebench", "/usr/bin/true",
                                "--config", "configs/mock-step.yaml", "--out", str(out)],
    "characterize": lambda out: [sys.executable, str(SCRIPTS / "characterize.py"), "--voicebench", "/usr/bin/true",
                                 "--out", str(out)],
    "checkpoint": lambda out: [sys.executable, str(SCRIPTS / "checkpoint.py"), "M1", "--out", str(out)],
    "offline_smoke": lambda out: ["bash", str(SCRIPTS / "offline_smoke.sh"), "/usr/bin/true", sys.executable, str(out)],
    "smoke": lambda out: ["bash", str(SCRIPTS / "smoke.sh"), "--out", str(out)],
}


@pytest.mark.parametrize("name", sorted(REFUSAL_CASES))
def test_existing_output_is_refused_and_left_byte_identical(name: str, tmp_path: Path) -> None:
    out, before = _populated(tmp_path)
    result = subprocess.run(REFUSAL_CASES[name](out), cwd=PROJECT_ROOT, capture_output=True, text=True, timeout=120)
    assert result.returncode != 0, f"{name} accepted an existing output directory"
    assert "exist" in (result.stderr + result.stdout) or "not empty" in result.stderr
    assert _tree(out) == before, f"{name} changed existing output"


def test_acceptance_refuses_an_existing_case_directory(tmp_path: Path) -> None:
    out = tmp_path / "acceptance"
    (out / "V01").mkdir(parents=True)
    (out / "V01" / "SENTINEL").write_text("keep\n")
    before = _tree(out)
    result = subprocess.run([sys.executable, str(SCRIPTS / "acceptance.py"), "--voicebench", "/usr/bin/true",
                             "--out", str(out), "--only", "V01"], cwd=PROJECT_ROOT, capture_output=True, text=True,
                            timeout=120)
    assert result.returncode != 0 and "V01" in result.stderr
    assert _tree(out) == before


# --- setup.sh refuses before touching anything ---------------------------------------------------

def test_setup_rejects_a_non_312_interpreter(tmp_path: Path) -> None:
    root = tmp_path / "checkout"
    (root / "scripts").mkdir(parents=True)
    shutil.copy2(SCRIPTS / "setup.sh", root / "scripts" / "setup.sh")
    wrong = _fake_python(tmp_path, "python3.14", "3.14.0")
    result = subprocess.run(["bash", str(root / "scripts/setup.sh"), "--python", str(wrong), "--skip-build"],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode != 0 and "requires 3.12" in result.stderr
    assert not (root / ".venv").exists(), "no environment may be created for a wrong interpreter"


def test_setup_preserves_an_incompatible_existing_venv(tmp_path: Path) -> None:
    root = tmp_path / "checkout"
    (root / "scripts").mkdir(parents=True)
    (root / ".venv" / "bin").mkdir(parents=True)
    shutil.copy2(SCRIPTS / "setup.sh", root / "scripts" / "setup.sh")
    _fake_python(root / ".venv" / "bin", "python", "3.11.9")
    (root / ".venv" / "SENTINEL").write_text("user environment\n")
    before = _tree(root / ".venv")
    good = _fake_python(tmp_path, "python3.12", "3.12.14")
    result = subprocess.run(["bash", str(root / "scripts/setup.sh"), "--python", str(good), "--skip-build"],
                            capture_output=True, text=True, timeout=120)
    assert result.returncode != 0 and "never replaces or deletes" in result.stderr
    assert _tree(root / ".venv") == before


# --- smoke accounting --------------------------------------------------------------------------

def _smoke_check():
    spec = importlib.util.spec_from_file_location("smoke_check", SCRIPTS / "smoke_check.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def smoke_run(voicebench: Path, tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, Path]:
    from phase0_analysis.export import export_run

    run = sealed_run(voicebench, "mock-step.yaml", tmp_path_factory.mktemp("smoke"), "smoke")
    validate = subprocess.run([str(voicebench), "validate", "--run", str(run)], capture_output=True, text=True,
                              timeout=300, cwd=PROJECT_ROOT)
    assert validate.returncode == 0, validate.stderr
    export = run.parent / "export"
    export_run(run, export, "all")
    return run, export


def test_smoke_check_accepts_a_genuine_mock_run(smoke_run: tuple[Path, Path]) -> None:
    run, export = smoke_run
    assert _smoke_check().check(run, export, 192000) == []


def test_smoke_check_requires_the_full_fixture_sample_count(smoke_run: tuple[Path, Path]) -> None:
    run, export = smoke_run
    problems = _smoke_check().check(run, export, 192001)
    assert any("consumed_samples" in p for p in problems)


@pytest.mark.parametrize("tamper, expected", [
    (lambda run: _edit(run / "runtime_summary.json", ["coverage", "dropped_samples"], 320), "dropped samples"),
    (lambda run: _edit(run / "predictions.json", ["mock"], False), "not labelled mock"),
    (lambda run: _edit(run / "status.json", ["state"], "failed"), "run state"),
    (lambda run: (run / "telemetry.jsonl").unlink(), "missing run artifacts"),
    (lambda run: shutil.rmtree(run / "derived"), "no derived validation"),
])
def test_smoke_check_rejects_tampered_runs(smoke_run: tuple[Path, Path], tmp_path: Path, tamper, expected: str) -> None:
    run, export = smoke_run
    copy = tmp_path / "run"
    shutil.copytree(run, copy)
    tamper(copy)
    problems = _smoke_check().check(copy, export, 192000)
    assert any(expected in p for p in problems), problems


def test_smoke_check_requires_export_files(smoke_run: tuple[Path, Path], tmp_path: Path) -> None:
    run, _ = smoke_run
    empty = tmp_path / "export"
    empty.mkdir()
    problems = _smoke_check().check(run, empty, 192000)
    assert any("missing export files" in p for p in problems) and any("PNG" in p for p in problems)


def _edit(path: Path, keys: list[str], value) -> None:
    data = json.loads(path.read_text())
    target = data
    for key in keys[:-1]:
        target = target[key]
    target[keys[-1]] = value
    path.write_text(json.dumps(data))
