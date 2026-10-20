"""Event trace reading and the ``logical_trace_v1`` determinism projection (plan G2).

Raw traces are never modified. The projection keeps events and fields whose
logical behaviour is defined in step mode, drops measured timing, and keeps the
existing append order (renumbering ``sequence``): it never sorts events to hide
a race. Unknown event types or payload fields are an error, never silently
dropped, so a schema change forces this allowlist to be revisited.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from .schemas import loads_strict

NORMALIZER_ID = "logical_trace_v1"

TERMINAL = {"experiment.completed", "experiment.failed", "experiment.cancelled"}

#: Envelope fields kept by the projection (run_id, sequence and monotonic_* are volatile).
ENVELOPE_KEEP = ("event_id", "stream_id", "source_id", "producer_id", "producer_sequence", "type",
                 "media_start_sample", "media_end_sample", "sample_rate_hz", "virtual_emitted_ns",
                 "cause_chunk_index", "invocation_id")
ENVELOPE_ALL = set(ENVELOPE_KEEP) | {"schema_version", "run_id", "sequence", "monotonic_emitted_ns",
                                     "monotonic_recorded_ns", "payload"}

#: Event types removed entirely: measured timing, telemetry and backpressure depend on the host.
DROPPED_TYPES = {"stage.completed", "telemetry.sample", "audio.queue_backpressure"}

#: type -> (kept payload fields, dropped volatile payload fields). Every field must be listed.
PAYLOAD_RULES: dict[str, tuple[set[str], set[str]]] = {
    "experiment.started": ({"mode", "settings_sha256", "manifest_sha256", "audio_sha256", "schema_bundle_sha256"}, set()),
    "experiment.runtime_completed": ({"produced_samples", "admitted_samples", "consumed_samples", "dropped_samples",
                                      "dropped_ranges", "last_media_sample"}, {"replay_elapsed_ns"}),
    # Terminal digests cover files that embed run IDs and wall-clock times.
    "experiment.completed": (set(), {"artifacts"}),
    "experiment.failed": ({"failure"}, {"last_valid_sequence"}),
    "experiment.cancelled": ({"failure"}, {"last_valid_sequence"}),
    "audio.chunk_scheduled": ({"chunk_index", "start_sample", "end_sample", "deadline_convention",
                               "planned_deadline_ns", "media_deadline_virtual_ns"}, set()),
    "audio.chunk_delivered": ({"chunk_index", "queue_depth", "delivered_virtual_ns"},
                              {"offer_ns", "entry_ns", "wake_error_ns", "deadline_error_ns"}),
    "audio.chunk_consumed": ({"chunk_index", "start_sample", "end_sample", "invocation_ids", "queue_depth"},
                             {"dequeue_ns", "finish_ns"}),
    "audio.queue_overflow": ({"chunk_index", "policy", "start_sample", "end_sample", "lost_samples",
                              "cumulative_lost_samples"}, set()),
    "adapter.started": ({"role", "adapter_id", "revision", "capabilities"}, set()),
    "adapter.stopped": ({"role", "adapter_id", "shutdown"}, set()),
    "adapter.failed": ({"role", "adapter_id", "stage", "message"}, set()),
    "adapter.diagnostic": ({"role", "adapter_id", "code", "message", "required_range", "missing_ranges"}, set()),
    "transcript.partial": ({"utterance_id", "revision", "text", "is_final"}, set()),
    "transcript.final": ({"utterance_id", "revision", "text", "is_final"}, set()),
    "speaker.segment": ({"segment_id", "speaker_id", "is_final"}, set()),
}


class NormalizerError(ValueError):
    """Raised for an event the projection does not know how to handle."""


@dataclass(frozen=True)
class Trace:
    path: Path
    raw: bytes
    events: list[dict[str, Any]]

    @property
    def line_count(self) -> int:
        return len(self.events)


def read_trace(path: Path, byte_limit: int | None = None) -> Trace:
    """Strictly parses a JSONL trace (optionally only its first ``byte_limit`` bytes)."""
    raw = Path(path).read_bytes()
    if byte_limit is not None:
        raw = raw[:byte_limit]
    if raw and not raw.endswith(b"\n"):
        raise ValueError(f"{path}: trace does not end at a line boundary (truncated write?)")
    events = [loads_strict(line) for line in raw.split(b"\n") if line]
    return Trace(Path(path), raw, events)


def prefix_descriptor(raw: bytes, path: str = "events.jsonl") -> dict[str, Any]:
    return {"path": path, "byte_count": len(raw), "line_count": raw.count(b"\n"),
            "sha256": hashlib.sha256(raw).hexdigest()}


def project_event(event: dict[str, Any]) -> dict[str, Any] | None:
    unknown = set(event) - ENVELOPE_ALL
    if unknown:
        raise NormalizerError(f"unknown envelope fields {sorted(unknown)} in {event.get('event_id')}")
    kind = event["type"]
    if kind in DROPPED_TYPES:
        return None
    if kind not in PAYLOAD_RULES:
        raise NormalizerError(f"event type {kind!r} has no {NORMALIZER_ID} rule")
    keep, volatile = PAYLOAD_RULES[kind]
    payload = event["payload"]
    unexpected = set(payload) - keep - volatile
    if unexpected:
        raise NormalizerError(f"{kind}: unknown payload fields {sorted(unexpected)}")
    projected = {key: event[key] for key in ENVELOPE_KEEP}
    projected["payload"] = {key: payload[key] for key in sorted(keep) if key in payload}
    return projected


def normalize(events: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Projects events, renumbering ``sequence`` in the existing append order."""
    out = []
    for event in events:
        projected = project_event(event)
        if projected is not None:
            projected["sequence"] = len(out)
            out.append(projected)
    return out


def normalized_bytes(events: list[dict[str, Any]]) -> bytes:
    return b"".join(json.dumps(e, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
                    for e in events)


def first_difference(a: list[dict[str, Any]], b: list[dict[str, Any]]) -> dict[str, Any] | None:
    """Locates the first differing projected event and field, for diagnostics."""
    for index, (x, y) in enumerate(zip(a, b)):
        if x != y:
            fields = sorted(k for k in set(x) | set(y) if x.get(k) != y.get(k))
            return {"index": index, "fields": fields, "left": x, "right": y}
    if len(a) != len(b):
        return {"index": min(len(a), len(b)), "fields": ["<length>"], "left_count": len(a), "right_count": len(b)}
    return None


#: predictions.json fields removed by the projection (run identity and trace digests embed volatile data).
PREDICTION_VOLATILE = {"run_id", "source_events"}


def project_predictions(predictions: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in predictions.items() if k not in PREDICTION_VOLATILE}


def project_metrics(metrics: dict[str, Any]) -> dict[str, Any]:
    """Accuracy values/components, policies and deterministic integrity counts only."""
    return {
        "policies": metrics["policies"],
        "accuracy": metrics["accuracy"],
        "data_integrity": {k: v for k, v in metrics["data_integrity"].items()
                           if v.get("clock_domain") in ("none", "media")},
    }
