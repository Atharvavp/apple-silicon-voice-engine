#!/usr/bin/env python3
"""Read-only, uniform reduction of the saved Phase 1 telemetry and supervisor observations.

Phase 1 follow-up Step 0 (review F06/F07). For every measured run it reports, with one
explicit scope and window each:
  * runner-process sampled RSS / phys_footprint maxima and the time of the footprint maximum
    (seconds after the first telemetry sample; 1 s sampling, so short peaks can be missed);
  * the median/min/max footprint over the 500 samples immediately before the `end` sample;
  * the supervisor's `observed_peak_rss_bytes` (one runner PID via `ps -o rss= -p <pid>`,
    polled over a longer window that includes post-telemetry artifact and scoring work);
  * active-adapter service seconds and the maximum chunk processing lag from metrics.json.
Writes one JSON file to a new path; never writes inside the campaign packet.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

MIB = 1024 * 1024


def telemetry(run: Path) -> dict:
    samples = [json.loads(line) for line in (run / "telemetry.jsonl").open()]
    t0 = samples[0]["measured_ns"]
    def value(s, key):
        m = s["measurements"].get(key, {})
        return m.get("value") if m.get("status") == "ok" else None
    rss = [(s, value(s, "rss_bytes")) for s in samples]
    fp = [(s, value(s, "physical_footprint_bytes")) for s in samples]
    rss_ok = [(s, v) for s, v in rss if v is not None]
    fp_ok = [(s, v) for s, v in fp if v is not None]
    peak_s, peak_v = max(fp_ok, key=lambda p: p[1])
    end_index = next(i for i, s in enumerate(samples) if s["phase"] == "end")
    late = [v for s, v in fp[max(0, end_index - 500):end_index] if v is not None]
    def window(lo, hi):
        vals = [v for s, v in fp_ok if lo <= (s["measured_ns"] - t0) / 1e9 < hi]
        return [round(min(vals) / MIB, 1), round(max(vals) / MIB, 1)] if vals else None
    return {
        "samples": len(samples),
        "rss_ok_samples": len(rss_ok),
        "footprint_ok_samples": len(fp_ok),
        "peak_rss_mib": round(max(v for _, v in rss_ok) / MIB, 1),
        "peak_footprint_mib": round(peak_v / MIB, 1),
        "peak_footprint_at_s": round((peak_s["measured_ns"] - t0) / 1e9, 1),
        "footprint_range_2_20s_mib": window(2, 20),
        "footprint_range_20_30s_mib": window(20, 30),
        "late500_footprint_mib": {"median": round(statistics.median(late) / MIB, 1),
                                  "min": round(min(late) / MIB, 1), "max": round(max(late) / MIB, 1), "n": len(late)},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--campaign", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.out.exists():
        print(f"refusing to overwrite {args.out}", file=sys.stderr)
        return 2
    ledger = [json.loads(line) for line in (args.campaign / "ledger.jsonl").open()]
    measured = {e["run_id"]: e for e in ledger if e.get("kind") == "measured"}
    rows = {}
    for run_id in sorted(measured):
        run = args.campaign / "runs" / run_id
        env = json.loads((run / "environment.json").read_text())
        metrics = json.loads((run / "metrics.json").read_text())
        rows[run_id] = {
            **telemetry(run),
            "supervisor_one_pid_peak_rss_mib": round(measured[run_id]["observed_peak_rss_bytes"] / MIB, 1),
            "environment_memory_bytes": env["hardware"]["memory_bytes"]["value"],
            "processing_lag_p95_ms": round(metrics["timing"]["processing_lag_ns"]["p95"] / 1e6, 1),
            "processing_lag_max_ms": round(metrics["timing"]["processing_lag_ns"]["max"] / 1e6, 1),
            "adapter_service_rtf": metrics["throughput"]["adapter_service_rtf"]["value"],
        }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"reduction": "memory_reanalysis_v1", "runs": rows}, indent=2) + "\n")
    for run_id, r in rows.items():
        print(run_id, {k: v for k, v in r.items()})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
