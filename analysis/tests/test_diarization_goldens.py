"""DER/JER against independent hand-derived goldens (V09)."""

from __future__ import annotations

import json

import pytest

from conftest import PROJECT_ROOT
from phase0_analysis import diarization_metrics as dm

GOLDEN = json.loads((PROJECT_ROOT / "testdata/goldens/diarization.json").read_text())
RATE = GOLDEN["rate"]


def speakers(rows: list) -> dict[str, list[tuple[int, int]]]:
    out: dict[str, list[tuple[int, int]]] = {}
    for label, start, end in rows:
        out.setdefault(label, []).append((start, end))
    return out


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda c: c["id"])
def test_golden_case(case: dict) -> None:
    reference = speakers(case.get("reference", GOLDEN["default_reference"]))
    hypothesis = speakers(case["hypothesis"])
    uem = [tuple(u) for u in case.get("uem", GOLDEN["default_uem"])]
    result = dm.score(reference, hypothesis, uem, RATE)
    for key in ("der", "jer"):
        if case[key] is None:
            assert result[key]["status"] == "not_computable" and result[key]["value"] is None
        else:
            assert result[key]["status"] == "ok", result[key]["reason"]
            assert result[key]["value"] == pytest.approx(case[key], abs=1e-9)
    if case.get("reason"):
        assert result["der"]["reason"] == case["reason"]
    components = result["der"]["components"]
    names = {"missed": "missed_seconds", "false_alarm": "false_alarm_seconds", "confusion": "confusion_seconds",
             "total": "total_seconds"}
    for key, expected in case.get("components", {}).items():
        assert components[names[key]] == pytest.approx(expected, abs=1e-9), key


def test_permutation_of_hypothesis_labels_does_not_change_scores() -> None:
    reference = speakers(GOLDEN["default_reference"])
    a = dm.score(reference, {"X": [(0, 6 * RATE)], "Y": [(6 * RATE, 8 * RATE)]}, [(0, 12 * RATE)], RATE)
    b = dm.score(reference, {"Q": [(0, 6 * RATE)], "P": [(6 * RATE, 8 * RATE)]}, [(0, 12 * RATE)], RATE)
    assert a["der"]["value"] == b["der"]["value"] and a["jer"]["value"] == b["jer"]["value"]


@pytest.mark.parametrize("case", GOLDEN["mapping"]["cases"], ids=lambda c: f"{c['sample']}@{c['rate_in']}")
def test_half_up_boundary_mapping(case: dict) -> None:
    assert dm.map_boundary(case["sample"], case["rate_in"], case["rate_out"], case["limit"]) == case["expected"]


def test_reference_mapping_records_quantization_and_collapsed_segments() -> None:
    document = {"timebase": {"sample_rate_hz": 48000}, "coverage": [{"start_sample": 0, "end_sample": 48000}],
                "segments": [{"segment_id": "a", "speaker_id": "A", "start_sample": 0, "end_sample": 24001},
                             {"segment_id": "tiny", "speaker_id": "B", "start_sample": 30000, "end_sample": 30001}]}
    mapped = dm.map_reference(document, 16000, 16000)
    assert mapped["speakers"]["A"] == [(0, 8000)]
    assert mapped["collapsed_segments"] == ["tiny"], "a one-sample 48 kHz segment collapses at 16 kHz and is reported"
    assert 0 < mapped["max_quantization_ns"] <= 31250  # at most half a 16 kHz sample
