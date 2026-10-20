"""Exports (V16): parseable CSVs with explicit statuses, Unicode preserved, plots rendered."""

from __future__ import annotations

import csv
from pathlib import Path

import pytest

from phase0_analysis.export import export_run


def rows(path: Path) -> list[dict]:
    with open(path, encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def test_csv_exports_keep_status_and_never_zero_fill(sealed: dict[str, Path], tmp_path: Path) -> None:
    written = export_run(sealed["step-a"], tmp_path / "out", "csv")
    assert set(written) == {"metrics.csv", "predictions.csv", "timing.csv", "resources.csv", "loss-ranges.csv"}
    metrics = rows(tmp_path / "out/metrics.csv")
    gpu = next(r for r in metrics if r["metric"] == "gpu_utilization")
    assert gpu["status"] == "unsupported" and gpu["value_or_p50"] == "" and gpu["reason"]
    wer = next(r for r in metrics if r["metric"] == "wer")
    assert float(wer["value_or_p50"]) == pytest.approx(0.4) and wer["mock"] == "True"
    timing = rows(tmp_path / "out/timing.csv")
    assert len(timing) == 600 and all(r["outcome"] == "accepted" for r in timing)


def test_unicode_survives_in_csv(sealed: dict[str, Path], tmp_path: Path) -> None:
    export_run(sealed["hindi"], tmp_path / "out", "csv")
    texts = [r["text"] for r in rows(tmp_path / "out/predictions.csv") if r["kind"] == "transcript"]
    assert texts == ["नमस्ते भारत", "की"]


def test_loss_ranges_are_exported(sealed: dict[str, Path], tmp_path: Path) -> None:
    export_run(sealed["drop"], tmp_path / "out", "csv")
    losses = rows(tmp_path / "out/loss-ranges.csv")
    assert losses and all(int(r["lost_samples"]) == int(r["end_sample"]) - int(r["start_sample"]) for r in losses)


def test_plots_render_nonempty_pngs(sealed: dict[str, Path], tmp_path: Path) -> None:
    written = export_run(sealed["step-a"], tmp_path / "out", "plots")
    assert len(written) == 3
    for name in written:
        data = (tmp_path / "out" / name).read_bytes()
        assert data.startswith(b"\x89PNG") and len(data) > 5_000


def test_existing_nonempty_output_is_refused(sealed: dict[str, Path], tmp_path: Path) -> None:
    (tmp_path / "out").mkdir()
    (tmp_path / "out/keep.txt").write_text("keep")
    with pytest.raises(FileExistsError):
        export_run(sealed["step-a"], tmp_path / "out", "csv")
