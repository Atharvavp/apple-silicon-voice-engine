"""Resource metrics from telemetry samples (V12)."""

from __future__ import annotations

import json

from conftest import PROJECT_ROOT
from phase0_analysis import resources

GOLDEN = json.loads((PROJECT_ROOT / "testdata/goldens/telemetry.json").read_text())


def test_cpu_rss_and_completeness_match_hand_values() -> None:
    r = resources.compute(GOLDEN["samples"], GOLDEN["sampler"])
    e = GOLDEN["expected"]
    cpu = r["cpu_percent"]
    assert (cpu["n"], cpu["p50"], cpu["p95"]) == (e["cpu_percent"]["n"], e["cpu_percent"]["p50"], e["cpu_percent"]["p95"])
    assert cpu["exclusions"] == [{"reason": k, "count": v} for k, v in e["cpu_percent"]["excluded"].items()]
    assert cpu["max"] > 100, "one-core basis is not clamped"
    assert r["rss_peak_sampled_bytes"]["value"] == e["rss_peak_sampled_bytes"]
    assert r["physical_footprint_peak_sampled_bytes"]["value"] == e["physical_footprint_peak_sampled_bytes"]
    assert r["telemetry_completeness"]["value"] == e["telemetry_completeness"]


def test_unsupported_counters_are_explicit_never_zero() -> None:
    r = resources.compute(GOLDEN["samples"], GOLDEN["sampler"])
    for key in ("gpu_utilization", "ane_utilization", "power_watts"):
        assert r[key]["status"] == "unsupported" and r[key]["value"] is None and r[key]["reason"]


def test_disabled_telemetry_is_unavailable_not_zero() -> None:
    r = resources.compute(None, None)
    assert r["cpu_percent"]["status"] == "not_computable" and r["cpu_percent"]["reason"] == "telemetry_disabled"
    assert r["rss_peak_sampled_bytes"]["status"] == "unavailable"
    assert r["telemetry_completeness"]["status"] == "unavailable"
