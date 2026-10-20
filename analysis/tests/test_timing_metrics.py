"""Timing/throughput formulas and joins on hand-built rows (V10)."""

from __future__ import annotations

import json

import pytest

from conftest import PROJECT_ROOT
from phase0_analysis import timing

GOLDEN = json.loads((PROJECT_ROOT / "testdata/goldens/timing.json").read_text())


@pytest.mark.parametrize("case", GOLDEN["percentiles"])
def test_nearest_rank(case: dict) -> None:
    d = timing.distribution(case["values"], "ns", "x", "monotonic", "a", "f")
    assert (d["p50"], d["p95"], d["min"], d["max"]) == (case["p50"], case["p95"], case["min"], case["max"])


def test_empty_distribution_is_not_computable() -> None:
    d = timing.distribution([], "ns", "x", "monotonic", "a", "f")
    assert d["status"] == "not_computable" and d["p50"] is None and d["reason"]


def build(mode: str = "realtime") -> tuple[list[dict], dict]:
    delay = GOLDEN["recorder_delay_ns"]

    def event(kind: str, payload: dict, emitted: int, cause=None, invocation=None) -> dict:
        return {"type": kind, "payload": payload, "monotonic_emitted_ns": emitted, "monotonic_recorded_ns": emitted + delay,
                "cause_chunk_index": cause, "invocation_id": invocation}

    events = []
    for c in GOLDEN["chunks"]:
        events.append(event("audio.chunk_scheduled", {"chunk_index": c["index"], "start_sample": c["start"],
                                                       "end_sample": c["end"], "planned_deadline_ns": c["planned"]},
                            c["offer"], c["index"]))
        events.append(event("audio.chunk_delivered", {"chunk_index": c["index"], "offer_ns": c["offer"],
                                                       "entry_ns": c["entry"],
                                                       "wake_error_ns": c["offer"] - c["planned"],
                                                       "deadline_error_ns": c["entry"] - c["planned"]},
                            c["entry"], c["index"]))
        events.append(event("audio.chunk_consumed", {"chunk_index": c["index"], "dequeue_ns": c["dequeue"],
                                                      "finish_ns": c["finish"]}, c["finish"], c["index"]))
    s = GOLDEN["stage"]
    events.append(event("stage.completed", {"stage": s["stage"], "start_ns": s["start"], "end_ns": s["end"],
                                            "duration_ns": s["end"] - s["start"], "virtual_duration_ns": None},
                        s["end"], 0, s["invocation"]))
    o = GOLDEN["output"]
    events.append(event("transcript.final", {}, o["emitted"], o["cause"], o["invocation"]))
    t = GOLDEN["throughput"]
    summary = {"replay": {"mode": mode, "sample_rate_hz": t["sample_rate_hz"], "total_frames": t["total_frames"],
                          "elapsed_ns": t["replay_elapsed_ns"], "speed": None},
               "phases": [{"phase": "drain", "start_ns": t["drain_end_ns"] - 1, "end_ns": t["drain_end_ns"]}],
               "clock": {"setup_start_ns": t["setup_start_ns"], "replay_anchor_ns": t["replay_anchor_ns"]},
               "coverage": {"consumed_samples": t["total_frames"]}}
    return events, summary


def test_realtime_formulas_and_joins_match_hand_values() -> None:
    events, summary = build()
    timing_group, throughput = timing.compute(events, summary)
    for key, expected in GOLDEN["expected"].items():
        d = timing_group[key]
        assert d["status"] == "ok", (key, d["reason"])
        for field in ("n", "p50", "p95", "min", "max"):
            if field in expected:
                assert d[field] == expected[field], (key, field)
        if "excluded" in expected:
            assert d["exclusions"] == [{"reason": "warmup_first_10s_media", "count": expected["excluded"]}]
    assert timing_group["recorder_admission_delay_ns"]["p50"] == GOLDEN["recorder_delay_ns"]
    for key, expected in GOLDEN["throughput"]["expected"].items():
        assert throughput[key]["value"] == pytest.approx(expected, rel=1e-12), key
    assert throughput["compute_only_rtf"]["status"] == "not_computable"
    assert timing_group["time_to_first_word_ns"]["status"] == "not_computable"


def test_step_mode_never_reports_live_latency() -> None:
    events, summary = build("step")
    timing_group, throughput = timing.compute(events, summary)
    for key in ("scheduler_wake_error_ns", "delivery_jitter_ns", "absolute_scheduling_error_ns", "processing_lag_ns"):
        assert timing_group[key]["status"] == "not_computable"
        assert timing_group[key]["reason"] == "step_mode_has_no_real_deadlines"
    assert timing_group["asr_consume_ns"]["definition_id"] == "adapter_consume_step_harness_v1"
    assert throughput["replay_rtf"]["definition_id"] == "replay_rtf_step_harness_v1"
    assert "virtual_asr_consume_delay_ns" in timing_group
    assert timing_group["virtual_asr_consume_delay_ns"]["clock_domain"] == "virtual"


def test_accelerated_definitions_are_distinct() -> None:
    events, summary = build("accelerated")
    timing_group, _ = timing.compute(events, summary)
    assert timing_group["delivery_jitter_ns"]["definition_id"] == "delivery_jitter_accelerated_v1"
