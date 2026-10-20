"""Doctor checks: installed graph, scorer imports, offline schemas (V19 foundation)."""

from __future__ import annotations

from pathlib import Path

from phase0_analysis import doctor


def test_doctor_passes_in_locked_environment(project_root: Path) -> None:
    report = doctor.run(project_root / "schemas/v1", project_root)
    failed = [c for c in report["checks"] if c["status"] != "pass"]
    assert report["status"] == "pass", failed


def test_forbidden_detection_is_case_and_separator_insensitive() -> None:
    assert doctor.forbidden_present(["Torch", "numpy", "pyannote_audio", "huggingface_hub"]) == [
        "Torch", "huggingface_hub", "pyannote_audio"]
    assert doctor.forbidden_present(["pyannote.metrics", "pyannote.core", "jiwer"]) == []


def test_every_installed_distribution_has_license_evidence() -> None:
    undeclared = [d["name"] for d in doctor.installed_distributions() if d["license"] == "UNDECLARED"]
    assert undeclared == [], f"no license metadata or license file: {undeclared}"
