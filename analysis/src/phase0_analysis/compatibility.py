"""Per-profile comparison compatibility (plan E4).

Every difference is reported as a field-level reason with an effect:
``blocks_ranking`` (the runs are not comparable under this profile) or
``disclosed`` (allowed to differ, but a reader must see it). Runs that are not
completed and sealed-valid, runs with data loss, step-mode live latency and
unverifiable hardware all block ranking. Nothing here rescores or edits a run.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .schemas import load_strict
from .validate import validate_run

PROFILES = ("accuracy", "latency", "resources")


def load_run(run: Path) -> dict[str, Any]:
    run = Path(run)
    docs: dict[str, Any] = {"path": str(run)}
    for name in ("config.json", "status.json", "runtime_summary.json", "environment.json", "metrics.json",
                 "predictions.json", "dataset_manifest_snapshot.json"):
        path = run / name
        docs[name] = load_strict(path) if path.exists() else None
    transcript = run / "references/transcript.json"
    docs["transcript_reference"] = load_strict(transcript) if transcript.exists() else None
    return docs


def _get(doc: Any, *keys: str) -> Any:
    for key in keys:
        if not isinstance(doc, dict) or key not in doc:
            return None
        doc = doc[key]
    return doc


def _fact(env: dict | None, key: str) -> Any:
    fact = _get(env, "hardware", key)
    return fact["value"] if isinstance(fact, dict) and fact.get("status") == "ok" else "unverified"


def _definitions(metrics: dict | None, group: str) -> dict[str, str]:
    return {k: v["definition_id"] for k, v in sorted((_get(metrics, group) or {}).items())}


def keys(run: dict[str, Any], profile: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """(blocking keys, disclosed keys) for one run under a profile."""
    config, summary, env = run["config.json"], run["runtime_summary.json"], run["environment.json"]
    metrics, predictions = run["metrics.json"], run["predictions.json"]
    settings = _get(config, "settings") or {}
    conversion = _get(summary, "conversion") or {}
    item_id = _get(config, "inputs", "item_id")
    items = _get(run["dataset_manifest_snapshot.json"], "items") or []
    languages = next((i["languages"] for i in items if i["item_id"] == item_id), None)
    inputs = {
        "source_id": _get(predictions, "source_id"),
        "inputs.audio_sha256": _get(config, "inputs", "audio_sha256"),
        "conversion.converted_sha256": conversion.get("converted_sha256"),
        "conversion.target_rate_hz": conversion.get("target_rate_hz"),
        "conversion.intended_frames": conversion.get("intended_frames"),
        "policy_ids.downmix": _get(config, "policy_ids", "downmix"),
        "policy_ids.conversion": _get(config, "policy_ids", "conversion"),
        "policy_ids.endpoint": _get(config, "policy_ids", "endpoint"),
        "conversion.endpoint_status": conversion.get("endpoint_status"),
        "schema_bundle.sha256": _get(config, "schema_bundle", "sha256"),
    }
    blocking: dict[str, Any] = dict(inputs)
    disclosed: dict[str, Any] = {
        "adapters.asr": f"{_get(settings, 'adapters', 'asr', 'id')}@{_get(settings, 'adapters', 'asr', 'revision')}",
        "adapters.diarization": (f"{_get(settings, 'adapters', 'diarization', 'id')}@"
                                 f"{_get(settings, 'adapters', 'diarization', 'revision')}"),
        "seed": _get(settings, "seed"),
    }
    if profile == "accuracy":
        blocking.update({
            "inputs.reference_sha256": _get(config, "inputs", "reference_sha256"),
            "reference.granularity": _get(run["transcript_reference"], "granularity"),
            "languages": languages,
            "predictions.transcript_assembly_policy": _get(predictions, "transcript_assembly_policy"),
            "policies.text": _get(metrics, "policies", "text"),
            "policies.diarization": _get(metrics, "policies", "diarization"),
            "policies.scorers": _get(metrics, "policies", "scorers"),
            "mock": _get(metrics, "mock"),
        })
        disclosed.update({"replay.mode": _get(settings, "replay", "mode"),
                          "hardware.model": _fact(env, "model")})
    else:
        replay = _get(summary, "replay") or {}
        blocking.update({
            "replay.mode": replay.get("mode"), "replay.deadline_convention": replay.get("deadline_convention"),
            "replay.speed": replay.get("speed"), "replay.frame_samples": replay.get("frame_samples"),
            "replay.overflow": replay.get("overflow"), "replay.queue_capacity": replay.get("queue_capacity"),
            "adapters.delay_ms": [_get(settings, "adapters", r, "delay_ms") for r in ("asr", "diarization")],
            "timing.definitions": _definitions(metrics, "timing"),
            "hardware.model": _fact(env, "model"), "hardware.chip": _fact(env, "chip"),
            "hardware.memory_bytes": _fact(env, "memory_bytes"),
            "os.build_version": _get(env, "os", "build_version"), "toolchain.sdk_version": _get(env, "toolchain", "sdk_version"),
            "toolchain.build_configuration": _get(env, "toolchain", "build_configuration"),
            "build.voicebench_version": _get(env, "build", "voicebench_version"),
            "run_conditions.warm_state": _get(env, "run_conditions", "warm_state"),
            "run_conditions.background_load": _get(env, "run_conditions", "background_load"),
            "telemetry.enabled": _get(settings, "telemetry", "enabled"),
            "telemetry.interval_ms": _get(settings, "telemetry", "interval_ms"),
            "placement.requested": _get(env, "placement", "requested"),
        })
        if profile == "resources":
            blocking["resources.definitions"] = _definitions(metrics, "resources")
            blocking["telemetry_capabilities"] = {k: v.get("status") for k, v in
                                                  sorted((_get(env, "telemetry_capabilities") or {}).items())}
    return blocking, disclosed


def eligibility(run: dict[str, Any], schemas: Path, profile: str) -> list[dict[str, Any]]:
    """Run-level reasons (failed, unsealed, invalid, lossy, step latency, unverified hardware)."""
    reasons = []
    run_id = _get(run["config.json"], "run_id") or run["path"]
    state = _get(run["status.json"], "state")
    if state != "completed":
        reasons.append({"field": "status.state", "values": [run_id, state], "effect": "blocks_ranking"})
        return reasons
    report = validate_run(Path(run["path"]), schemas, "sealed")
    if report["status"] != "pass":
        failed = [c["check_id"] for c in report["checks"] if c["status"] == "fail"]
        reasons.append({"field": "validation.sealed", "values": [run_id, failed], "effect": "blocks_ranking"})
    for disclosure in report["disclosures"]:
        effect = "blocks_ranking" if disclosure["code"] == "data_loss" else "disclosed"
        reasons.append({"field": f"disclosure.{disclosure['code']}", "values": [run_id, disclosure["message"]],
                        "effect": effect})
    if profile != "accuracy":
        if _get(run["runtime_summary.json"], "replay", "mode") == "step":
            reasons.append({"field": "replay.mode", "values": [run_id, "step"], "effect": "blocks_ranking"})
        env = run["environment.json"]
        unverified = [k for k in ("model", "chip", "memory_bytes") if _fact(env, k) == "unverified"]
        if unverified:
            reasons.append({"field": "hardware.unverified", "values": [run_id, unverified], "effect": "blocks_ranking"})
    return reasons


def assess(runs: list[dict[str, Any]], profile: str, schemas: Path) -> list[dict[str, Any]]:
    if profile not in PROFILES:
        raise ValueError(f"unknown profile {profile}")
    reasons: list[dict[str, Any]] = []
    for run in runs:
        reasons.extend(eligibility(run, schemas, profile))
    per_run = [keys(run, profile) for run in runs]
    for field in sorted(set().union(*(set(b) for b, _ in per_run))):
        values = [b.get(field) for b, _ in per_run]
        if any(v != values[0] for v in values[1:]):
            reasons.append({"field": field, "values": values, "effect": "blocks_ranking"})
    for field in sorted(set().union(*(set(d) for _, d in per_run))):
        values = [d.get(field) for _, d in per_run]
        if any(v != values[0] for v in values[1:]):
            reasons.append({"field": field, "values": values, "effect": "disclosed"})
    return reasons
