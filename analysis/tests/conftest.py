from __future__ import annotations

import os
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="session")
def project_root() -> Path:
    return PROJECT_ROOT


@pytest.fixture(scope="session")
def voicebench() -> Path:
    """Built CLI used for cross-language parity. Missing binary is a failure, not a skip."""
    candidate = Path(os.environ.get("VOICEBENCH_BIN", PROJECT_ROOT / ".build/debug/voicebench"))
    if not candidate.is_file():
        pytest.fail(f"voicebench binary not found at {candidate}; run `swift build` first "
                    "(or set VOICEBENCH_BIN). Parity checks must not be skipped.")
    return candidate


import shutil
import subprocess


def runtime_stage(voicebench: Path, config: Path, runs: Path, run_id: str) -> Path:
    """Creates a genuine unsealed run directory with `voicebench dev runtime-stage`."""
    result = subprocess.run([str(voicebench), "dev", "runtime-stage", "--config", str(config), "--runs-dir", str(runs),
                             "--run-id", run_id], capture_output=True, timeout=300, check=False)
    assert result.returncode == 0, result.stderr.decode()
    return runs / run_id


@pytest.fixture(scope="session")
def step_run(voicebench: Path, tmp_path_factory: pytest.TempPathFactory) -> Path:
    return runtime_stage(voicebench, PROJECT_ROOT / "configs/mock-step.yaml", tmp_path_factory.mktemp("runs"), "step")


@pytest.fixture()
def step_copy(step_run: Path, tmp_path: Path) -> Path:
    """A private copy of the step run that a test may tamper with."""
    target = tmp_path / "run"
    shutil.copytree(step_run, target)
    return target


def sealed_run(voicebench: Path, config: str, runs: Path, run_id: str, *extra: str) -> Path:
    """A completed, sealed run produced by the production `voicebench run`."""
    result = subprocess.run([str(voicebench), "run", "--config", str(PROJECT_ROOT / "configs" / config), "--runs-dir",
                             str(runs), "--run-id", run_id, *extra], capture_output=True, timeout=600, check=False)
    assert result.returncode == 0, result.stderr.decode() + result.stdout.decode()
    return runs / run_id


@pytest.fixture(scope="session")
def sealed(voicebench: Path, tmp_path_factory: pytest.TempPathFactory) -> dict[str, Path]:
    runs = tmp_path_factory.mktemp("sealed")
    return {
        "step-a": sealed_run(voicebench, "mock-step.yaml", runs, "step-a"),
        "step-b": sealed_run(voicebench, "mock-step.yaml", runs, "step-b"),
        "hindi": sealed_run(voicebench, "mock-step-hi.yaml", runs, "hindi"),
        "endpoint": sealed_run(voicebench, "mock-step-endpoint.yaml", runs, "endpoint"),
        "drop": sealed_run(voicebench, "mock-slow-drop.yaml", runs, "drop"),
        "seed": sealed_run(voicebench, "mock-step.yaml", runs, "seed", "--seed", "7"),
    }
