"""``score``: metrics.json from a run's immutable runtime outputs (plan C3 step 6).

Inputs are only the frozen runtime prefix, ``runtime_summary.json``,
``predictions.json``, the telemetry sidecar and the run's own reference copies.
Nothing in the run is edited: the initial analysis writes ``metrics.json`` and
an ``initial``-stage ``validation.json`` exclusively; a rescore writes both
into a new ``derived/<analysis_id>/`` directory.
"""

from __future__ import annotations

import hashlib
import importlib.metadata as metadata
from pathlib import Path
from typing import Any

from . import asr_metrics, diarization_metrics, normalization, resources, timing
from .schemas import SchemaStore, load_strict, loads_strict
from .trace import read_trace
from .validate import sha256_file, validate_run

TRANSCRIPT_ASSEMBLY = "media_order_space_join_v1"


def reference_text(document: dict[str, Any]) -> str:
    if document["granularity"] == "recording":
        return document["recording_text"]
    return " ".join(s["text"] for s in sorted(document["segments"], key=lambda s: (s["start_sample"], s["segment_id"])))


def hypothesis_text(predictions: dict[str, Any]) -> str:
    """``media_order_space_join_v1``: finals in prediction-view order, joined by one space."""
    return " ".join(t["text"] for t in predictions["transcript"])


def _digest(run: Path, relative: str) -> dict[str, Any]:
    path = run / relative
    return {"path": relative, "byte_count": path.stat().st_size, "sha256": sha256_file(path)}


def accuracy(run: Path, predictions: dict[str, Any], policy: str) -> dict[str, Any]:
    out: dict[str, Any] = {}
    transcript = run / "references/transcript.json"
    speakers = run / "references/speakers.json"
    if transcript.exists():
        reference = reference_text(load_strict(transcript))
        hypothesis = hypothesis_text(predictions)
        out["wer"] = asr_metrics.wer(reference, hypothesis)
        out["cer"] = asr_metrics.cer(reference, hypothesis)
    else:
        for key, definition in (("wer", "wer_v1"), ("cer", "cer_codepoint_v1")):
            out[key] = timing.scalar(None, "ratio", definition, "none", 0, f"no_transcript_reference_{policy}")
    if speakers.exists():
        audio = predictions["audio"]
        mapped = diarization_metrics.map_reference(load_strict(speakers), audio["sample_rate_hz"], audio["duration_samples"])
        hypothesis: dict[str, list[tuple[int, int]]] = {}
        for segment in predictions["speakers"]:
            hypothesis.setdefault(segment["speaker_id"], []).append((segment["start_sample"], segment["end_sample"]))
        scored = diarization_metrics.score(mapped["speakers"], hypothesis, mapped["uem"], audio["sample_rate_hz"],
                                           predictions["source_id"])
        for record in scored.values():
            record["components"].update({"reference_rate_hz": mapped["source_rate_hz"],
                                         "max_boundary_quantization_ns": mapped["max_quantization_ns"],
                                         "collapsed_reference_segments": mapped["collapsed_segments"]})
        out.update(scored)
    else:
        for key in ("der", "jer"):
            out[key] = timing.scalar(None, "ratio", f"{key}_v1", "media", 0, f"no_speaker_reference_{policy}")
    return out


def data_integrity(events: list[dict[str, Any]], summary: dict[str, Any]) -> dict[str, Any]:
    coverage, conversion = summary["coverage"], summary["conversion"]
    count = lambda kind: sum(1 for e in events if e["type"] == kind)
    finals = {(e["producer_id"], e["payload"]["utterance_id"]) for e in events if e["type"] == "transcript.final"}
    partial_only = {(e["producer_id"], e["payload"]["utterance_id"]) for e in events
                    if e["type"] == "transcript.partial"} - finals
    integ: dict[str, Any] = {}
    for key in ("produced_samples", "admitted_samples", "consumed_samples", "dropped_samples"):
        integ[key] = timing.scalar(coverage[key], "samples", f"{key}_v1", "media", coverage[key])
    integ["dropped_chunks"] = timing.scalar(count("audio.queue_overflow"), "chunks", "dropped_chunks_v1", "media",
                                            count("audio.queue_overflow"))
    integ["data_loss"] = timing.scalar(1.0 if summary["data_loss"] else 0.0, "boolean", "data_loss_v1", "media", 1,
                                       components={"dropped_ranges": coverage["dropped_ranges"],
                                                   "accuracy_ranking": "excluded" if summary["data_loss"] else "eligible"})
    corrected = conversion["trimmed_tail_frames"] + conversion["zero_extended_tail_frames"]
    integ["endpoint_corrected_frames"] = timing.scalar(
        corrected, "frames", "endpoint_correction_v1", "media", 1,
        components={k: conversion[k] for k in ("endpoint_policy", "endpoint_status", "native_frames", "intended_frames",
                                               "trimmed_tail_frames", "zero_extended_tail_frames")})
    integ["suppressed_outputs"] = timing.scalar(count("adapter.diagnostic"), "events", "suppressed_outputs_v1", "none",
                                                count("adapter.diagnostic"))
    integ["unfinalized_utterances"] = timing.scalar(len(partial_only), "utterances", "unfinalized_utterances_v1", "none",
                                                    len(partial_only),
                                                    components={"utterances": sorted(u for _, u in partial_only)})
    return integ


def score_run(run: Path, schemas: Path, analysis_id: str = "initial") -> dict[str, Any]:
    run = Path(run)
    config = load_strict(run / "config.json")
    summary = load_strict(run / "runtime_summary.json")
    predictions = load_strict(run / "predictions.json")
    descriptor = summary["events_prefix"]
    trace_path = run / "events.jsonl" if (run / "events.jsonl").exists() else run / "events.jsonl.partial"
    prefix = read_trace(trace_path, descriptor["byte_count"])
    if hashlib.sha256(prefix.raw).hexdigest() != descriptor["sha256"] or prefix.line_count != descriptor["line_count"]:
        raise ValueError("runtime prefix does not match runtime_summary.events_prefix; refusing to score")
    telemetry = None
    if summary["telemetry"] is not None:
        telemetry = [loads_strict(line) for line in (run / summary["telemetry"]["path"]).read_bytes().splitlines()]
    timing_group, throughput_group = timing.compute(prefix.events, summary)
    references = [_digest(run, f"references/{n}.json") for n in ("transcript", "speakers")
                  if (run / f"references/{n}.json").exists()]
    settings = config["settings"]["scoring"]
    metrics = {
        "schema_version": "1.0", "run_id": config["run_id"], "source_id": predictions["source_id"],
        "analysis_id": analysis_id, "mock": predictions["mock"],
        "inputs": {"predictions_sha256": sha256_file(run / "predictions.json"), "references": references,
                   "source_events": descriptor},
        "policies": {"text": settings["text_policy"], "diarization": settings["diarization_policy"],
                     "scorers": {"jiwer": metadata.version("jiwer"),
                                 "pyannote.metrics": metadata.version("pyannote.metrics"),
                                 "text_policy_unicode": normalization.policy_fingerprint()["unicode_version"],
                                 "text_policy_implementation": normalization.policy_fingerprint()["implementation_sha256"],
                                 "transcript_assembly": TRANSCRIPT_ASSEMBLY, "percentiles": "nearest_rank_v1"}},
        "accuracy": accuracy(run, predictions, settings["references"]),
        "timing": timing_group, "throughput": throughput_group,
        "resources": resources.compute(telemetry, summary["telemetry_sampler"]),
        "data_integrity": data_integrity(prefix.events, summary),
    }
    issues = SchemaStore(schemas).issues("metrics", metrics)
    if issues:
        raise ValueError(f"computed metrics violate metrics.schema.json: {issues[:3]}")
    return metrics


def initial_validation(run: Path, schemas: Path) -> dict[str, Any]:
    return validate_run(run, schemas, "initial", validation_id="initial")
