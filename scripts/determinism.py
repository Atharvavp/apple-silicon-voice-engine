#!/usr/bin/env python3
"""V05/V18: run the same step-mode config in N separate `voicebench run` processes and
compare the ``logical_trace_v1`` projections of events, predictions and metrics
exactly (plan G2). Raw artifacts are kept; projections are written beside them.

    .venv/bin/python scripts/determinism.py --voicebench .build/release/voicebench \
        --config configs/mock-step.yaml --repeats 3 --out evidence/M7/determinism
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "analysis/src"))

from phase0_analysis.trace import (  # noqa: E402
    NORMALIZER_ID, first_difference, normalize, normalized_bytes, project_metrics, project_predictions, read_trace,
)


def canonical(value) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicebench", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    runs = out / "runs"
    runs.mkdir(parents=True)
    results, projections = [], []
    for n in range(args.repeats):
        run_id = f"det-{n + 1}"
        proc = subprocess.run([str(Path(args.voicebench).resolve()), "run", "--config", args.config, "--runs-dir", str(runs),
                               "--run-id", run_id], cwd=ROOT, capture_output=True, text=True, timeout=600, check=False)
        results.append({"run_id": run_id, "exit_code": proc.returncode, "stderr_tail": proc.stderr[-1000:]})
        if proc.returncode != 0:
            continue
        run = runs / run_id
        events = normalize(read_trace(run / "events.jsonl").events)
        (run / "normalized-events.jsonl").write_bytes(normalized_bytes(events))
        predictions = project_predictions(json.loads((run / "predictions.json").read_text()))
        metrics = project_metrics(json.loads((run / "metrics.json").read_text()))
        projections.append({"run_id": run_id, "events": events, "predictions": predictions, "metrics": metrics})
        results[-1].update({
            "normalized_events_sha256": hashlib.sha256(normalized_bytes(events)).hexdigest(),
            "normalized_event_count": len(events),
            "predictions_projection_sha256": hashlib.sha256(canonical(predictions)).hexdigest(),
            "metrics_projection_sha256": hashlib.sha256(canonical(metrics)).hexdigest(),
            "raw_events_sha256": hashlib.sha256((run / "events.jsonl").read_bytes()).hexdigest(),
        })
    complete = len(projections) == args.repeats
    differences = []
    for other in projections[1:]:
        base = projections[0]
        diff = first_difference(base["events"], other["events"])
        if diff or base["predictions"] != other["predictions"] or base["metrics"] != other["metrics"]:
            differences.append({"run_id": other["run_id"], "events": diff,
                                "predictions_equal": base["predictions"] == other["predictions"],
                                "metrics_equal": base["metrics"] == other["metrics"]})
    raw_distinct = len({r.get("raw_events_sha256") for r in results}) == len(results)
    report = {"normalizer": NORMALIZER_ID, "config": args.config, "repeats": args.repeats, "runs": results,
              "status": "pass" if complete and not differences else "fail", "differences": differences,
              "raw_traces_distinct": raw_distinct,
              "note": "Raw traces differ (run IDs, real timestamps); only the versioned projection is compared, "
                      "in append order, never re-sorted."}
    (out / "equality.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"determinism: {report['status']} ({len(projections)}/{args.repeats} runs)")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
