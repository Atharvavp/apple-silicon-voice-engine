"""Trace reading and the logical_trace_v1 projection (V05/V18 foundations, plan G2)."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import PROJECT_ROOT, runtime_stage
from phase0_analysis.schemas import load_strict
from phase0_analysis.trace import (
    NormalizerError, first_difference, normalize, normalized_bytes, prefix_descriptor, project_event, read_trace,
)


def test_prefix_descriptor_matches_runtime_summary(step_run: Path) -> None:
    trace = read_trace(step_run / "events.jsonl.partial")
    summary = load_strict(step_run / "runtime_summary.json")
    assert prefix_descriptor(trace.raw) == summary["events_prefix"]


def test_truncated_trace_is_rejected(step_copy: Path) -> None:
    path = step_copy / "events.jsonl.partial"
    path.write_bytes(path.read_bytes()[:-7])
    with pytest.raises(ValueError, match="line boundary"):
        read_trace(path)


def test_projection_drops_timing_and_renumbers_in_append_order(step_run: Path) -> None:
    events = read_trace(step_run / "events.jsonl.partial").events
    projected = normalize(events)
    kinds = {e["type"] for e in projected}
    assert not kinds & {"stage.completed", "telemetry.sample", "audio.queue_backpressure"}
    assert [e["sequence"] for e in projected] == list(range(len(projected)))
    kept = [e["event_id"] for e in events if e["type"] not in {"stage.completed", "telemetry.sample"}]
    assert [e["event_id"] for e in projected] == kept, "append order is preserved, never re-sorted"
    delivered = next(e for e in projected if e["type"] == "audio.chunk_delivered")
    assert set(delivered["payload"]) == {"chunk_index", "queue_depth", "delivered_virtual_ns"}
    assert all("monotonic_emitted_ns" not in e and "run_id" not in e for e in projected)


def test_unknown_fields_and_types_fail_closed(step_run: Path) -> None:
    event = next(e for e in read_trace(step_run / "events.jsonl.partial").events if e["type"] == "transcript.final")
    with pytest.raises(NormalizerError):
        project_event(dict(event, payload=dict(event["payload"], confidence=0.9)))
    with pytest.raises(NormalizerError):
        project_event(dict(event, type="transcript.revised"))
    with pytest.raises(NormalizerError):
        project_event(dict(event, extra=1))


def test_three_step_runs_have_identical_projections(voicebench: Path, tmp_path: Path) -> None:
    runs = [runtime_stage(voicebench, PROJECT_ROOT / "configs/mock-step.yaml", tmp_path, f"det-{n}") for n in range(3)]
    projections = [normalized_bytes(normalize(read_trace(r / "events.jsonl.partial").events)) for r in runs]
    assert projections[0] == projections[1] == projections[2]
    raw = [(r / "events.jsonl.partial").read_bytes() for r in runs]
    assert raw[0] != raw[1], "raw traces differ (run IDs, timestamps); only the projection is compared"


def test_first_difference_names_the_field() -> None:
    a = [{"type": "x", "payload": {"text": "a"}}]
    b = [{"type": "x", "payload": {"text": "b"}}]
    assert first_difference(a, b)["fields"] == ["payload"]
    assert first_difference(a, a) is None
