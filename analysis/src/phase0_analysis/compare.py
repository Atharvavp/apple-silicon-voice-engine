"""``compare``: side-by-side report of completed runs under one profile (plan E4/M6).

A ranking is produced only when every run is compatible and every primary
metric is ``ok``. ``--allow-noncomparable`` emits labelled side-by-side rows
but never a ranking or a winner; it does not rescore or waive anything.
"""

from __future__ import annotations

import csv
import io
import uuid
from pathlib import Path
from typing import Any

from .compatibility import assess, load_run
from .validate import now

#: profile -> metrics shown as rows (group, key); the first is the ranking key (lower is better).
PROFILE_METRICS = {
    "accuracy": [("accuracy", "wer"), ("accuracy", "der"), ("accuracy", "cer"), ("accuracy", "jer")],
    "latency": [("timing", "absolute_scheduling_error_post_warmup_ns"), ("timing", "absolute_scheduling_error_ns"),
                ("timing", "delivery_jitter_ns"), ("timing", "processing_lag_ns"),
                ("timing", "event_emission_latency_ns"), ("throughput", "replay_rtf"),
                ("throughput", "end_to_end_rtf")],
    "resources": [("resources", "rss_peak_sampled_bytes"), ("resources", "cpu_percent"),
                  ("resources", "physical_footprint_peak_sampled_bytes"), ("resources", "gpu_utilization")],
}


def as_record(metric: dict[str, Any] | None) -> dict[str, Any]:
    """Normalizes a metric (scalar or distribution) to the metric_record shape used in rows."""
    if metric is None:
        return {"status": "unavailable", "value": None, "unit": "none", "definition_id": "missing",
                "sample_count": 0, "clock_domain": "none", "reason": "metric_not_present", "components": {}}
    if "p95" not in metric:
        return metric
    components = {k: metric[k] for k in ("p50", "p95", "min", "max", "n", "percentile_method", "exclusions")}
    return {"status": metric["status"], "value": metric["p95"] if metric["status"] == "ok" else None,
            "unit": metric["unit"], "definition_id": metric["definition_id"] + "#p95", "sample_count": metric["n"],
            "clock_domain": metric["clock_domain"], "reason": metric["reason"], "components": components}


def compare(paths: list[Path], profile: str, schemas: Path, allow_noncomparable: bool) -> dict[str, Any]:
    runs = [load_run(p) for p in paths]
    reasons = assess(runs, profile, schemas)
    compatible = not any(r["effect"] == "blocks_ranking" for r in reasons)
    run_ids = [(r["config.json"] or {}).get("run_id", Path(r["path"]).name) for r in runs]
    rows = []
    for run, run_id in zip(runs, run_ids):
        for group, key in PROFILE_METRICS[profile]:
            record = as_record(((run["metrics.json"] or {}).get(group) or {}).get(key))
            rows.append({"run_id": run_id, "metric": f"{group}.{key}", "metric_record": record})
            if record["status"] != "ok":
                reasons.append({"field": f"incomplete_measurement.{group}.{key}", "values": [run_id, record["reason"]],
                                "effect": "disclosed"})
    ranking = None
    if compatible:
        group, key = PROFILE_METRICS[profile][0]
        primary = {row["run_id"]: row["metric_record"] for row in rows if row["metric"] == f"{group}.{key}"}
        if all(r["status"] == "ok" for r in primary.values()):
            ranking = sorted(primary, key=lambda rid: (primary[rid]["value"], rid))
        else:
            reasons.append({"field": f"ranking.{group}.{key}", "values": ["primary metric not ok for every run"],
                            "effect": "disclosed"})
    return {
        "schema_version": "1.0", "comparison_id": f"comparison-{uuid.uuid4().hex[:12]}", "created_wall_time": now(),
        "profile": profile, "runs": run_ids, "compatible": compatible, "allow_noncomparable": allow_noncomparable,
        "reasons": reasons, "rows": rows, "ranking": ranking,
    }


def to_csv(report: dict[str, Any]) -> str:
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(["comparison_id", "profile", "compatible", "label", "run_id", "metric", "status", "value", "unit",
                     "definition_id", "reason"])
    label = "comparable" if report["compatible"] else "NONCOMPARABLE"
    for row in report["rows"]:
        r = row["metric_record"]
        writer.writerow([report["comparison_id"], report["profile"], report["compatible"], label, row["run_id"],
                         row["metric"], r["status"], "" if r["value"] is None else repr(r["value"]), r["unit"],
                         r["definition_id"], r["reason"] or ""])
    return out.getvalue()
