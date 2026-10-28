"""Timing and throughput metrics joined from the runtime prefix (plan E3).

All real durations come from one run-relative monotonic clock (integer ns);
media time is samples / rate. Joins use chunk indices and invocation IDs, never
nearest timestamps. Quantiles use nearest rank ``sorted[ceil(p*n) - 1]``.

Step mode has no real deadlines, so live scheduling metrics are
``not_computable``; its measured durations are labelled *step harness
execution* (distinct definition IDs) and virtual values live under
``virtual_*`` names with clock domain ``virtual``. They are never latency.
"""

from __future__ import annotations

import math
from collections import defaultdict
from typing import Any

WARMUP_NS = 10_000_000_000


def nearest_rank(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[max(math.ceil(p * len(ordered)) - 1, 0)]


def distribution(values: list[float], unit: str, definition: str, domain: str, artifact: str, field: str,
                 exclusions: list[dict[str, Any]] | None = None, reason: str | None = None) -> dict[str, Any]:
    base = {"unit": unit, "definition_id": definition, "clock_domain": domain, "n": len(values),
            "percentile_method": "nearest_rank_v1", "exclusions": exclusions or [],
            "source": {"artifact": artifact, "field": field}}
    if not values:
        return {**base, "status": "not_computable", "p50": None, "p95": None, "min": None, "max": None,
                "reason": reason or "no_samples"}
    return {**base, "status": "ok", "p50": float(nearest_rank(values, 0.5)), "p95": float(nearest_rank(values, 0.95)),
            "min": float(min(values)), "max": float(max(values)), "reason": None}


def scalar(value: float | None, unit: str, definition: str, domain: str, count: int, reason: str | None = None,
           components: dict[str, Any] | None = None, status: str | None = None) -> dict[str, Any]:
    if value is None or (isinstance(value, float) and not math.isfinite(value)):
        return {"status": status or "not_computable", "value": None, "unit": unit, "definition_id": definition,
                "sample_count": count, "clock_domain": domain, "reason": reason or "no_samples",
                "components": components or {}}
    return {"status": "ok", "value": float(value), "unit": unit, "definition_id": definition, "sample_count": count,
            "clock_domain": domain, "reason": None, "components": components or {}}


def compute(events: list[dict[str, Any]], summary: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Returns (timing, throughput) metric groups."""
    replay = summary["replay"]
    mode, rate = replay["mode"], replay["sample_rate_hz"]
    step = mode == "step"
    label = "_step_harness" if step else ("_accelerated" if mode == "accelerated" else "")
    by_type: dict[str, list[dict]] = defaultdict(list)
    for event in events:
        by_type[event["type"]].append(event)
    scheduled = {e["payload"]["chunk_index"]: e["payload"] for e in by_type["audio.chunk_scheduled"]}
    delivered = {e["payload"]["chunk_index"]: e["payload"] for e in by_type["audio.chunk_delivered"]}
    consumed = {e["payload"]["chunk_index"]: e["payload"] for e in by_type["audio.chunk_consumed"]}
    stages_by_invocation = {e["invocation_id"]: e["payload"] for e in by_type["stage.completed"] if e["invocation_id"]}
    t: dict[str, Any] = {}
    ev = "events.jsonl"

    # Live scheduling (real/accelerated only): delivery = admission into the shared queue.
    if step:
        for key, definition, field in (
                ("scheduler_wake_error_ns", "scheduler_wake_error_v1", "payload.wake_error_ns"),
                ("delivery_jitter_ns", "delivery_jitter_v1", "payload.deadline_error_ns"),
                ("absolute_scheduling_error_ns", "absolute_scheduling_error_v1", "payload.deadline_error_ns"),
                ("absolute_scheduling_error_post_warmup_ns", "absolute_scheduling_error_post_warmup_v1",
                 "payload.deadline_error_ns"),
                ("processing_lag_ns", "processing_lag_v1", "payload.finish_ns - planned_deadline_ns")):
            t[key] = distribution([], "ns", definition, "monotonic", ev, field, reason="step_mode_has_no_real_deadlines")
    else:
        wake = [p["wake_error_ns"] for p in delivered.values()]
        jitter = [p["deadline_error_ns"] for p in delivered.values()]
        warm = [abs(p["deadline_error_ns"]) for i, p in delivered.items()
                if scheduled[i]["end_sample"] * 1_000_000_000 // rate > WARMUP_NS]
        excluded = len(jitter) - len(warm)
        t["scheduler_wake_error_ns"] = distribution(wake, "ns", f"scheduler_wake_error{label}_v1", "monotonic", ev,
                                                    "audio.chunk_delivered.payload.wake_error_ns")
        t["delivery_jitter_ns"] = distribution(jitter, "ns", f"delivery_jitter{label}_v1", "monotonic", ev,
                                               "audio.chunk_delivered.payload.deadline_error_ns")
        t["absolute_scheduling_error_ns"] = distribution([abs(v) for v in jitter], "ns",
                                                         f"absolute_scheduling_error{label}_v1", "monotonic", ev,
                                                         "abs(audio.chunk_delivered.payload.deadline_error_ns)")
        t["absolute_scheduling_error_post_warmup_ns"] = distribution(
            warm, "ns", f"absolute_scheduling_error_post_warmup{label}_v1", "monotonic", ev,
            "abs(deadline_error_ns) for chunks whose media deadline is after 10 s",
            exclusions=[{"reason": "warmup_first_10s_media", "count": excluded}],
            reason="no_chunks_after_the_10_s_warmup")
        lag = [consumed[i]["finish_ns"] - scheduled[i]["planned_deadline_ns"] for i in consumed if i in scheduled]
        t["processing_lag_ns"] = distribution(lag, "ns", f"processing_lag{label}_v1", "monotonic", ev,
                                              "audio.chunk_consumed.payload.finish_ns - planned_deadline_ns")
    blocked = [p["entry_ns"] - p["offer_ns"] for p in delivered.values()]
    t["producer_blocked_ns"] = distribution(blocked, "ns", f"producer_blocked{label}_v1", "monotonic", ev,
                                            "entry_ns - offer_ns")
    residence = [consumed[i]["dequeue_ns"] - delivered[i]["entry_ns"] for i in consumed if i in delivered]
    t["queue_residence_ns"] = distribution(residence, "ns", f"queue_residence{label}_v1", "monotonic", ev,
                                           "dequeue_ns - entry_ns")

    # Adapter invocations (include synchronous sink waits and configured delays; disclosed by definition).
    durations: dict[str, list[int]] = defaultdict(list)
    virtual: dict[str, list[int]] = defaultdict(list)
    for stage in by_type["stage.completed"]:
        name = stage["payload"]["stage"]
        durations[name].append(stage["payload"]["duration_ns"])
        if stage["payload"]["virtual_duration_ns"] is not None:
            virtual[name].append(stage["payload"]["virtual_duration_ns"])
    for role in ("asr", "diarization"):
        t[f"{role}_consume_ns"] = distribution(durations[f"{role}.consume"], "ns", f"adapter_consume{label}_v1",
                                               "monotonic", ev, f"stage.completed[{role}.consume].duration_ns")
        flush = durations[f"{role}.flush"]
        t[f"{role}_flush_ns"] = scalar(flush[0] if flush else None, "ns", f"adapter_flush{label}_v1", "monotonic",
                                       len(flush))
        if step:
            t[f"virtual_{role}_consume_delay_ns"] = distribution(
                virtual[f"{role}.consume"], "ns", "virtual_adapter_delay_v1", "virtual", ev,
                f"stage.completed[{role}.consume].virtual_duration_ns")

    # Output timing: emission relative to the causing invocation, and to the cause chunk's delivery.
    outputs = [e for kind in ("transcript.partial", "transcript.final", "speaker.segment", "adapter.diagnostic")
               for e in by_type[kind]]
    emission, delivery_to_output = [], []
    for event in outputs:
        stage = stages_by_invocation.get(event["invocation_id"])
        if stage is not None:
            emission.append(event["monotonic_emitted_ns"] - stage["start_ns"])
        cause = event["cause_chunk_index"]
        if cause is not None and cause in delivered:
            delivery_to_output.append(event["monotonic_emitted_ns"] - delivered[cause]["entry_ns"])
    t["event_emission_latency_ns"] = distribution(emission, "ns", f"event_emission_latency{label}_v1", "monotonic", ev,
                                                  "monotonic_emitted_ns - cause invocation start_ns",
                                                  reason="no_adapter_outputs")
    t["delivery_to_output_latency_ns"] = distribution(delivery_to_output, "ns", f"delivery_to_output{label}_v1",
                                                      "monotonic", ev,
                                                      "monotonic_emitted_ns - cause chunk entry_ns",
                                                      reason="no_chunk_caused_outputs")
    t["recorder_admission_delay_ns"] = distribution([e["monotonic_recorded_ns"] - e["monotonic_emitted_ns"] for e in events],
                                                    "ns", "recorder_admission_delay_v1", "monotonic", ev,
                                                    "monotonic_recorded_ns - monotonic_emitted_ns")
    t["time_to_first_word_ns"] = scalar(None, "ns", "time_to_first_word_v1", "monotonic", 0,
                                        reason="future_capability_not_computed_in_phase0")

    # Throughput (plan E3): RTFs over phase intervals from runtime_summary.json.
    phases = {p["phase"]: p for p in summary["phases"]}
    audio_ns = replay["total_frames"] * 1_000_000_000 // rate if rate else 0
    clock = summary["clock"]
    drain_end = phases["drain"]["end_ns"] if "drain" in phases else None
    service = sum(durations["asr.consume"]) + sum(durations["diarization.consume"]) + \
        sum(durations["asr.flush"]) + sum(durations["diarization.flush"])
    zero = "zero_audio_duration"
    th: dict[str, Any] = {}
    components = {"audio_duration_ns": audio_ns, "replay_mode": mode, "speed": replay["speed"]}
    th["end_to_end_rtf"] = scalar((drain_end - clock["setup_start_ns"]) / audio_ns if audio_ns and drain_end else None,
                                  "ratio", f"end_to_end_rtf{label}_v1", "monotonic", 1, zero,
                                  {**components, "interval": "setup_start -> runtime drain end (excludes scoring)"})
    th["replay_rtf"] = scalar((drain_end - clock["replay_anchor_ns"]) / audio_ns if audio_ns and drain_end else None,
                              "ratio", f"replay_rtf{label}_v1", "monotonic", 1, zero,
                              {**components, "interval": "replay anchor -> runtime drain end"})
    th["adapter_service_rtf"] = scalar(service / audio_ns if audio_ns else None, "ratio", f"adapter_service_rtf{label}_v1",
                                       "monotonic", 1, zero,
                                       {**components, "note": "sum of consume+flush wall durations, including configured delays and sink waits; not compute-only"})
    th["compute_only_rtf"] = scalar(None, "ratio", "compute_only_rtf_v1", "monotonic", 0,
                                    "adapter_does_not_expose_active_compute_time")
    elapsed_s = replay["elapsed_ns"] / 1e9
    consumed_samples = summary["coverage"]["consumed_samples"]
    th["consumed_samples_per_second"] = scalar(consumed_samples / elapsed_s if elapsed_s > 0 else None, "samples/s",
                                               f"consumed_throughput{label}_v1", "monotonic", consumed_samples,
                                               "zero_replay_elapsed")
    th["media_seconds_per_second"] = scalar((consumed_samples / rate) / elapsed_s if elapsed_s > 0 and rate else None,
                                            "ratio", f"media_throughput{label}_v1", "monotonic", consumed_samples,
                                            "zero_replay_elapsed")
    return t, th
