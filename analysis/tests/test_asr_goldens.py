"""WER/CER against independent hand-derived goldens (V08)."""

from __future__ import annotations

import json
import unicodedata

import pytest

from conftest import PROJECT_ROOT
from phase0_analysis import asr_metrics, normalization

GOLDEN = json.loads((PROJECT_ROOT / "testdata/goldens/asr.json").read_text(encoding="utf-8"))


def check(record: dict, expected: dict) -> None:
    c = record["components"]
    assert (c["substitutions"], c["deletions"], c["insertions"], c["reference_units"]) == \
        (expected["S"], expected["D"], expected["I"], expected["N"])
    if expected["value"] is None:
        assert record["status"] == "not_computable" and record["value"] is None
        assert record["reason"] == expected["reason"]
    else:
        assert record["status"] == "ok" and record["reason"] is None
        assert record["value"] == pytest.approx(expected["value"], abs=1e-9)


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda c: c["id"])
def test_golden_case(case: dict) -> None:
    check(asr_metrics.wer(case["reference"], case["hypothesis"]), case["wer"])
    check(asr_metrics.cer(case["reference"], case["hypothesis"]), case["cer"])


def test_policy_preserves_marks_and_scripts() -> None:
    text = normalization.normalize("क़ि‍ १२ Ünïcode")
    assert "़" in text and "‍" in text and "१२" in text, "nukta, ZWJ and Devanagari digits survive"
    assert text == unicodedata.normalize("NFC", text)
    assert normalization.normalize("a.b") == "a b" and normalization.normalize("a+b") == "a+b", "symbols are kept"


def test_cer_counts_code_points_not_graphemes() -> None:
    assert normalization.code_points("कि") == ["क", "ि"]


def test_policy_fingerprint_names_the_policy_and_unicode_tables() -> None:
    fingerprint = normalization.policy_fingerprint()
    assert fingerprint["policy_id"] == "nfc_casefold_punct_space_cp_v1"
    assert fingerprint["unicode_version"] == unicodedata.unidata_version
