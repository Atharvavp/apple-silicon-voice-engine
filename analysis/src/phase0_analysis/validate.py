"""Run artifact validation (plan D6, V13-V15).

Stages:
  ``runtime``  after the runtime stage: no metrics and no terminal event yet.
  ``initial``  written by ``score`` before sealing: metrics present, still no terminal event.
  ``sealed``   any later check of a finished run: completed status, final trace,
               every sealed digest re-verified against the bytes on disk.

Nothing here edits a run. Endpoint corrections are disclosed (DEC-026); with
``strict`` endpoint policy, or ``require_exact_endpoints``, a correction fails.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import uuid
from collections import defaultdict
from pathlib import Path
from typing import Any

from .schemas import SchemaStore, StrictJSONError, canonical_bytes, load_strict
from .trace import TERMINAL, prefix_descriptor, read_trace

#: Documents checked against JSON Schema, per stage.
DOCUMENTS = [
    ("config.json", "config", "runtime"), ("config_settings.json", "config-settings", "runtime"),
    ("environment.json", "environment", "runtime"), ("dataset_manifest_snapshot.json", "dataset", "runtime"),
    ("runtime_summary.json", "runtime-summary", "runtime"), ("predictions.json", "predictions", "runtime"),
    ("status.json", "status", "runtime"), ("references/transcript.json", "annotations", "runtime"),
    ("references/speakers.json", "annotations", "runtime"), ("inputs/fixture_script.json", "fixture-script", "runtime"),
    ("metrics.json", "metrics", "initial"), ("validation.json", "validation", "sealed"),
]
STAGES = ("runtime", "initial", "sealed")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def schema_bundle_digest(schemas: Path) -> str:
    lines = "".join(f"{p.name} {sha256_file(p)}\n" for p in sorted(Path(schemas).glob("*.schema.json")))
    return hashlib.sha256(lines.encode()).hexdigest()


def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="milliseconds")


class Checks:
    def __init__(self) -> None:
        self.items: list[dict[str, Any]] = []
        self.disclosures: list[dict[str, str]] = []

    def add(self, check_id: str, ok: bool, message: str = "", evidence: str | None = None) -> bool:
        self.items.append({"check_id": check_id, "status": "pass" if ok else "fail", "message": message,
                           "evidence": evidence})
        return ok

    def not_run(self, check_id: str, message: str) -> None:
        self.items.append({"check_id": check_id, "status": "not_run", "message": message, "evidence": None})

    def disclose(self, code: str, message: str) -> None:
        self.disclosures.append({"code": code, "message": message})


def rebuild_predictions(events: list[dict[str, Any]]) -> tuple[list[dict], list[dict]]:
    """Independent re-implementation of the Swift prediction view (finals only, media order)."""
    transcript, speakers = [], []
    for e in events:
        if e["type"] == "transcript.final":
            transcript.append({"utterance_id": e["payload"]["utterance_id"], "start_sample": e["media_start_sample"],
                               "end_sample": e["media_end_sample"], "text": e["payload"]["text"],
                               "event_ids": [e["event_id"]]})
        elif e["type"] == "speaker.segment":
            speakers.append({"segment_id": e["payload"]["segment_id"], "speaker_id": e["payload"]["speaker_id"],
                             "start_sample": e["media_start_sample"], "end_sample": e["media_end_sample"],
                             "event_ids": [e["event_id"]]})
    transcript.sort(key=lambda t: (-1 if t["start_sample"] is None else t["start_sample"], t["utterance_id"]))
    speakers.sort(key=lambda s: (s["start_sample"], s["segment_id"]))
    return transcript, speakers


def check_transcript_transitions(events: list[dict[str, Any]]) -> list[str]:
    problems, state = [], {}
    for e in events:
        if e["type"] not in ("transcript.partial", "transcript.final"):
            continue
        key = (e["producer_id"], e["payload"]["utterance_id"])
        revision, final = e["payload"]["revision"], e["type"] == "transcript.final"
        previous = state.get(key)
        if previous == "final":
            problems.append(f"{key[1]}: event after final ({e['event_id']})")
        elif previous is not None and revision <= previous:
            problems.append(f"{key[1]}: revision {revision} does not increase past {previous}")
        state[key] = "final" if final else revision
    return problems


def check_chunk_coverage(events: list[dict[str, Any]], total: int, lossless: bool) -> tuple[list[str], dict[str, int]]:
    by_type: dict[str, dict[int, dict]] = defaultdict(dict)
    problems = []
    for e in events:
        if e["type"] in ("audio.chunk_scheduled", "audio.chunk_delivered", "audio.chunk_consumed", "audio.queue_overflow"):
            index = e["payload"]["chunk_index"]
            if index in by_type[e["type"]]:
                problems.append(f"duplicate {e['type']} for chunk {index}")
            by_type[e["type"]][index] = e["payload"]
    scheduled = by_type["audio.chunk_scheduled"]
    cursor = 0
    for index in range(len(scheduled)):
        chunk = scheduled.get(index)
        if chunk is None:
            problems.append(f"chunk {index} was never scheduled")
            break
        if chunk["start_sample"] != cursor:
            problems.append(f"chunk {index} starts at {chunk['start_sample']}; expected {cursor}")
        cursor = chunk["end_sample"]
    if cursor != total:
        problems.append(f"scheduled chunks cover [0, {cursor}); the stream has {total} samples")
    delivered, dropped, consumed = (set(by_type[t]) for t in
                                    ("audio.chunk_delivered", "audio.queue_overflow", "audio.chunk_consumed"))
    if delivered & dropped:
        problems.append(f"chunks both delivered and dropped: {sorted(delivered & dropped)[:5]}")
    if (delivered | dropped) != set(scheduled):
        problems.append("every scheduled chunk must be delivered or dropped exactly once")
    if consumed != delivered:
        problems.append("consumed chunks differ from delivered chunks")
    if lossless and dropped:
        problems.append(f"{len(dropped)} chunks dropped under the lossless block policy")
    span = lambda ids: sum(scheduled[i]["end_sample"] - scheduled[i]["start_sample"] for i in ids if i in scheduled)
    counts = {"produced": span(scheduled), "admitted": span(delivered), "consumed": span(consumed), "dropped": span(dropped)}
    return problems, counts


def validate_run(run: Path, schemas: Path, stage: str = "sealed", require_exact_endpoints: bool = False,
                 validation_id: str | None = None) -> dict[str, Any]:
    if stage not in STAGES:
        raise ValueError(f"unknown stage {stage}")
    run = Path(run)
    store = SchemaStore(schemas)
    c = Checks()
    docs: dict[str, Any] = {}
    stage_rank = STAGES.index(stage)

    # 1. Schema validity of every document this stage requires.
    for name, target, needed_from in DOCUMENTS:
        path = run / name
        required = STAGES.index(needed_from) <= stage_rank
        optional = name.startswith(("references/", "inputs/"))
        if not path.exists():
            if required and not optional:
                c.add(f"schema:{name}", False, "missing")
            continue
        try:
            docs[name] = load_strict(path)
            issues = store.issues(target, docs[name])
            c.add(f"schema:{name}", not issues, "; ".join(map(str, issues[:3])), name)
        except StrictJSONError as exc:
            c.add(f"schema:{name}", False, f"not strict JSON: {exc}", name)
    config, summary = docs.get("config.json"), docs.get("runtime_summary.json")
    if config is None or summary is None:
        return finish(run, stage, c, validation_id)

    # 2. Schema bundle: the reader must be the bundle the run was written under.
    current = schema_bundle_digest(schemas)
    c.add("schema_bundle:matches", current == config["schema_bundle"]["sha256"],
          f"run {config['schema_bundle']['sha256'][:12]}, reader {current[:12]}")

    # 3. Inputs: settings preimage, manifest snapshot, references, script.
    settings_bytes = (run / "config_settings.json").read_bytes()
    c.add("inputs:settings_hash", hashlib.sha256(settings_bytes).hexdigest() == config["settings_sha256"]
          and canonical_bytes(docs["config_settings.json"]) == settings_bytes and
          docs["config_settings.json"] == config["settings"], "settings_json_v1 preimage, digest and frozen copy agree")
    c.add("inputs:manifest_snapshot", sha256_file(run / "dataset_manifest_snapshot.json") == config["inputs"]["manifest_sha256"])
    refs = {name: sha256_file(run / f"references/{name}.json") if (run / f"references/{name}.json").exists() else None
            for name in ("transcript", "speakers")}
    if config["inputs"]["reference_sha256"] is not None:
        descriptor = hashlib.sha256(f"{refs['transcript'] or '-'}\n{refs['speakers'] or '-'}\n".encode()).hexdigest()
        c.add("inputs:reference_copies", descriptor == config["inputs"]["reference_sha256"],
              "reference copies match the manifest descriptor hash")
    if config["inputs"]["fixture_script_sha256"] is not None:
        c.add("inputs:fixture_script_copy",
              sha256_file(run / "inputs/fixture_script.json") == config["inputs"]["fixture_script_sha256"])

    # 4. Trace: prefix identity, structure, sequence, ordering rules.
    status = docs.get("status.json", {})
    trace_name = "events.jsonl" if stage == "sealed" else "events.jsonl.partial"
    if not (run / trace_name).exists():
        c.add("events:present", False, f"{trace_name} missing (status {status.get('state')})")
        return finish(run, stage, c, validation_id)
    descriptor = summary["events_prefix"]
    try:
        whole = read_trace(run / trace_name)
        prefix = read_trace(run / trace_name, descriptor["byte_count"])
    except (ValueError, StrictJSONError) as exc:
        c.add("events:parse", False, str(exc))
        return finish(run, stage, c, validation_id)
    c.add("events:prefix_descriptor", prefix_descriptor(prefix.raw) == descriptor,
          "first byte_count bytes hash to the runtime prefix descriptor")
    bad = [i for i, e in enumerate(whole.events) if store.issues("event", e)]
    c.add("events:schema", not bad, f"{len(bad)} invalid lines (first: {bad[:5]})", trace_name)
    c.add("events:sequence_contiguous", [e["sequence"] for e in whole.events] == list(range(len(whole.events))))
    c.add("events:recorded_after_emitted",
          all(e["monotonic_recorded_ns"] >= e["monotonic_emitted_ns"] for e in whole.events))
    c.add("events:runtime_prefix_shape", bool(prefix.events) and prefix.events[0]["type"] == "experiment.started"
          and prefix.events[-1]["type"] == "experiment.runtime_completed"
          and not any(e["type"] in TERMINAL for e in prefix.events),
          "prefix starts with experiment.started and ends with experiment.runtime_completed")
    tail = whole.events[prefix.line_count:]
    if stage == "sealed":
        c.add("events:single_terminal", len(tail) == 1 and tail[0]["type"] == "experiment.completed",
              f"{len(tail)} events after the prefix")
    else:
        c.add("events:no_terminal_yet", not tail, f"{len(tail)} events after the prefix")
    transitions = check_transcript_transitions(prefix.events)
    c.add("events:transcript_transitions", not transitions, "; ".join(transitions[:3]))
    ids = [e["event_id"] for e in whole.events]
    c.add("events:unique_ids", len(ids) == len(set(ids)))

    # 5. Coverage: chunk tiling and sample accounting agree across trace, summary and predictions.
    replay = summary["replay"]
    lossless = replay["overflow"] == "block"
    problems, counts = check_chunk_coverage(prefix.events, replay["total_frames"], lossless)
    coverage = summary["coverage"]
    completed = next((e["payload"] for e in prefix.events if e["type"] == "experiment.runtime_completed"), {})
    agree = (counts["produced"] == coverage["produced_samples"] == completed.get("produced_samples")
             and counts["admitted"] == coverage["admitted_samples"] == completed.get("admitted_samples")
             and counts["consumed"] == coverage["consumed_samples"] == completed.get("consumed_samples")
             and counts["dropped"] == coverage["dropped_samples"] == completed.get("dropped_samples"))
    c.add("coverage:chunks", not problems and agree, "; ".join(problems[:3]) or f"counts {counts}")
    if summary["data_loss"]:
        c.disclose("data_loss", f"{coverage['dropped_samples']} samples dropped in {len(coverage['dropped_ranges'])} "
                                f"ranges (drop_newest); excluded from direct accuracy rankings")

    # 6. Conversion disclosure (DEC-025/DEC-026) and spool integrity.
    conversion = summary["conversion"]
    corrected = conversion["endpoint_status"] in ("trimmed_one_frame", "zero_extended_one_frame")
    consistent = (conversion["native_frames"] - conversion["trimmed_tail_frames"]
                  + conversion["zero_extended_tail_frames"] == conversion["intended_frames"])
    c.add("conversion:record_consistent", consistent and conversion["endpoint_policy"] == config["settings"]["audio"]["endpoint_policy"],
          f"policy {conversion['endpoint_policy']}, status {conversion['endpoint_status']}, native "
          f"{conversion['native_frames']}, intended {conversion['intended_frames']}")
    if corrected:
        c.disclose("endpoint_correction",
                   f"{conversion['endpoint_status']}: native {conversion['native_frames']} frames, intended "
                   f"{conversion['intended_frames']} (trimmed {conversion['trimmed_tail_frames']}, zero-extended "
                   f"{conversion['zero_extended_tail_frames']}) under {conversion['endpoint_policy']}")
    strict = conversion["endpoint_policy"] == "strict" or require_exact_endpoints
    c.add("conversion:strict_endpoints" if strict else "conversion:endpoint_disclosed",
          not (strict and corrected),
          ("strict endpoint policy: " if strict else "disclosed: ") + conversion["endpoint_status"])
    integrity = summary["integrity"]
    predictions = docs.get("predictions.json")
    c.add("integrity:spool", integrity["pre_replay_verified"] and integrity["end_of_stream_verified"]
          and integrity["spool_sha256"] == conversion["converted_sha256"]
          and (predictions is None or predictions["audio"]["converted_sha256"] == conversion["converted_sha256"]))

    # 7. Predictions are exactly the prefix's finals.
    if predictions is not None:
        transcript, speakers = rebuild_predictions(prefix.events)
        c.add("predictions:rebuild", predictions["transcript"] == transcript and predictions["speakers"] == speakers
              and predictions["source_events"] == descriptor
              and predictions["coverage"]["dropped_ranges"] == coverage["dropped_ranges"],
              "predictions.json equals an independent rebuild from the runtime prefix")

    # 8. Telemetry sidecar.
    telemetry = summary["telemetry"]
    if telemetry is not None:
        path = run / telemetry["path"]
        lines = path.read_bytes().splitlines() if path.exists() else []
        invalid = sum(1 for line in lines if store.issues("telemetry", load_line(line)))
        c.add("telemetry:sidecar", path.exists() and sha256_file(path) == telemetry["sha256"]
              and len(lines) == telemetry["line_count"] and invalid == 0,
              f"{len(lines)} lines, {invalid} invalid")

    # 9. Metrics reference the same immutable inputs.
    metrics = docs.get("metrics.json")
    if metrics is not None:
        c.add("metrics:inputs", metrics["inputs"]["predictions_sha256"] == sha256_file(run / "predictions.json")
              and metrics["inputs"]["source_events"] == descriptor
              and all(sha256_file(run / r["path"]) == r["sha256"] for r in metrics["inputs"]["references"]),
              "metrics were computed from these predictions, references and prefix")
        c.add("metrics:mock_label", metrics["mock"] == (predictions or {}).get("mock", metrics["mock"]))

    # 10. Sealed runs: status commit marker and every digest.
    if stage == "sealed":
        ok_state = status.get("state") == "completed"
        c.add("status:completed", ok_state, f"state {status.get('state')}")
        mismatched = []
        for artifact in status.get("artifacts") or []:
            path = run / artifact["path"]
            if not path.exists() or path.stat().st_size != artifact["byte_count"] or sha256_file(path) != artifact["sha256"]:
                mismatched.append(artifact["path"])
        c.add("status:artifact_digests", ok_state and not mismatched, f"mismatched: {mismatched}")
        terminal = tail[0]["payload"]["artifacts"] if len(tail) == 1 and tail[0]["type"] == "experiment.completed" else None
        sealed = [a for a in status.get("artifacts") or [] if a["path"] != "events.jsonl"]
        c.add("status:terminal_matches", terminal is not None and terminal == sealed,
              "experiment.completed lists exactly the sealed artifacts except the trace itself")
        c.add("status:last_sequence", status.get("last_event_sequence") == len(whole.events) - 1)
    return finish(run, stage, c, validation_id)


def load_line(line: bytes) -> Any:
    from .schemas import loads_strict

    return loads_strict(line)


def finish(run: Path, stage: str, c: Checks, validation_id: str | None) -> dict[str, Any]:
    failed = [i for i in c.items if i["status"] == "fail"]
    return {
        "schema_version": "1.0",
        "validation_id": validation_id or f"validation-{uuid.uuid4().hex[:12]}",
        "created_wall_time": now(),
        "target": {"kind": "run", "path": str(run)},
        "stage": stage,
        "status": "fail" if failed else "pass",
        "checks": c.items,
        "disclosures": c.disclosures,
    }
