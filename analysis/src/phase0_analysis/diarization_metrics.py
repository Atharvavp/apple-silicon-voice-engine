"""DER and JER, policy ``pyannote_c0_overlap_uem_v1`` (plan E2).

pyannote.metrics 4.2.0, metrics-only: ``DiarizationErrorRate`` and
``JaccardErrorRate`` with ``collar=0.0, skip_overlap=False`` and an explicit
UEM built from the reference's declared scored regions (silence included).
Speaker mapping is the scorer's own Hungarian mapping; it is recorded, not
re-derived. Boundaries stay integer samples until the pyannote boundary,
where they become ``samples / rate`` seconds.

Reference boundaries authored at another rate are mapped to the stream rate
with the half-up rule ``floor((s * Rout + floor(Rin / 2)) / Rin)`` and clamped
to the stream length (plan D2 item 11); the largest mapping error is recorded.
Same-speaker overlaps are unioned before scoring. Installed 4.2.0 returns 0.0
or 1.0 for an empty DER denominator and 1.0 for JER with no reference
speakers; both become ``not_computable`` here, with false-alarm time kept.
"""

from __future__ import annotations

from collections import defaultdict
from fractions import Fraction
from typing import Any

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate, JaccardErrorRate

POLICY_ID = "pyannote_c0_overlap_uem_v1"


def map_boundary(sample: int, rate_in: int, rate_out: int, limit: int) -> int:
    if rate_in == rate_out:
        return min(sample, limit)
    return min((sample * rate_out + rate_in // 2) // rate_in, limit)


def union(intervals: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def map_reference(document: dict[str, Any], rate_out: int, duration_out: int) -> dict[str, Any]:
    """Maps a speakers annotation document to the stream rate (integer samples)."""
    rate_in = document["timebase"]["sample_rate_hz"]
    worst = Fraction(0)
    collapsed = []

    def mapped(start: int, end: int, label: str) -> tuple[int, int] | None:
        nonlocal worst
        a, b = map_boundary(start, rate_in, rate_out, duration_out), map_boundary(end, rate_in, rate_out, duration_out)
        for original, new in ((start, a), (end, b)):
            worst = max(worst, abs(Fraction(new, rate_out) - Fraction(original, rate_in)))
        if b <= a:
            collapsed.append(label)
            return None
        return a, b

    speakers: dict[str, list[tuple[int, int]]] = defaultdict(list)
    for segment in document["segments"]:
        interval = mapped(segment["start_sample"], segment["end_sample"], segment["segment_id"])
        if interval:
            speakers[segment["speaker_id"]].append(interval)
    uem = [i for i in (mapped(r["start_sample"], r["end_sample"], "uem") for r in document["coverage"]) if i]
    return {"speakers": {k: union(v) for k, v in speakers.items()}, "uem": union(uem),
            "max_quantization_ns": int(worst * 1_000_000_000), "collapsed_segments": collapsed,
            "source_rate_hz": rate_in}


def _annotation(speakers: dict[str, list[tuple[int, int]]], rate: int, uri: str) -> Annotation:
    annotation = Annotation(uri=uri)
    for label in sorted(speakers):
        for index, (start, end) in enumerate(union(speakers[label])):
            annotation[Segment(start / rate, end / rate), f"{label}#{index}"] = label
    return annotation


def _overlap_samples(intervals: list[tuple[int, int]], uem: list[tuple[int, int]]) -> int:
    total = 0
    for start, end in intervals:
        for u0, u1 in uem:
            total += max(0, min(end, u1) - max(start, u0))
    return total


def score(reference: dict[str, list[tuple[int, int]]], hypothesis: dict[str, list[tuple[int, int]]],
          uem: list[tuple[int, int]], rate: int, uri: str = "item") -> dict[str, dict[str, Any]]:
    """DER and JER metric records for integer-sample speaker intervals at ``rate``."""
    uem = union(uem)
    uem_samples = sum(end - start for start, end in uem)
    ref_samples = sum(_overlap_samples(v, uem) for v in reference.values())
    hyp_samples = sum(_overlap_samples(union(v), uem) for v in hypothesis.values())
    base = {"uem_seconds": uem_samples / rate, "reference_speaker_seconds": ref_samples / rate,
            "hypothesis_speaker_seconds": hyp_samples / rate, "reference_speakers": len(reference),
            "hypothesis_speakers": len(hypothesis), "collar_seconds": 0.0, "skip_overlap": False}

    def missing(definition: str, reason: str, extra: dict[str, Any]) -> dict[str, Any]:
        return {"status": "not_computable", "value": None, "unit": "ratio", "definition_id": definition,
                "sample_count": 0, "clock_domain": "media", "reason": reason, "components": {**base, **extra}}

    if uem_samples == 0:
        return {"der": missing("der_v1", "empty_uem", {}), "jer": missing("jer_v1", "empty_uem", {})}
    ref_annotation = _annotation(reference, rate, uri)
    hyp_annotation = _annotation(hypothesis, rate, uri)
    timeline = Timeline([Segment(start / rate, end / rate) for start, end in uem], uri=uri)

    der_metric = DiarizationErrorRate(collar=0.0, skip_overlap=False)
    detail = der_metric(ref_annotation, hyp_annotation, uem=timeline, detailed=True)
    mapping = DiarizationErrorRate(collar=0.0, skip_overlap=False).optimal_mapping(ref_annotation, hyp_annotation,
                                                                                    uem=timeline)
    der_components = {**base, "missed_seconds": detail["missed detection"], "false_alarm_seconds": detail["false alarm"],
                      "confusion_seconds": detail["confusion"], "correct_seconds": detail["correct"],
                      "total_seconds": detail["total"], "mapping": {str(k): str(v) for k, v in sorted(mapping.items())}}
    if detail["total"] == 0:
        der = missing("der_v1", "zero_reference_speech", der_components)
    else:
        errors = detail["missed detection"] + detail["false alarm"] + detail["confusion"]
        der = {"status": "ok", "value": errors / detail["total"], "unit": "ratio", "definition_id": "der_v1",
               "sample_count": ref_samples, "clock_domain": "media", "reason": None, "components": der_components}

    jer_metric = JaccardErrorRate(collar=0.0, skip_overlap=False)
    jdetail = jer_metric(ref_annotation, hyp_annotation, uem=timeline, detailed=True)
    jer_components = {**base, "speaker_count": jdetail["speaker count"], "speaker_error_sum": jdetail["speaker error"]}
    if jdetail["speaker count"] == 0:
        jer = missing("jer_v1", "no_reference_speakers", jer_components)
    else:
        jer = {"status": "ok", "value": jdetail["speaker error"] / jdetail["speaker count"], "unit": "ratio",
               "definition_id": "jer_v1", "sample_count": int(jdetail["speaker count"]), "clock_domain": "media",
               "reason": None, "components": jer_components}
    return {"der": der, "jer": jer}
