#!/usr/bin/env python3
"""Performance characterization campaign (plan E3, P01-P04). Separate, serialized
`voicebench run` processes in real-time mode; never inside `swift test`.

P01  repeats x realtime runs of --realtime-seconds; signed/absolute admission error,
     full and with the first --warmup-seconds of media excluded (target: post-warm-up
     absolute p95 <= 20 ms, investigatory).
P02  one real-time run of --drift-seconds: exact sample accounting (correctness) and
     signed admission error vs media time with a least-squares trend (characterization;
     no universal drift tolerance is asserted).
P03  --overhead-pairs paired telemetry on/off runs of --overhead-seconds (alternating
     order); raw numbers only, no significance claim, no overhead subtraction.
P04  telemetry sampler completeness and capability statuses from the telemetry-on runs.

Raw run directories are retained. Host conditions (load averages, power source) are
recorded before and after every run; this script cannot make a host idle or controlled.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "analysis/src"))

from phase0_analysis.trace import read_trace  # noqa: E402

TARGET_P95_NS = 20_000_000


def capture(argv: list[str]) -> str | None:
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10, check=False).stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


def host_conditions() -> dict:
    return {"wall_time": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
            "load_average": capture(["sysctl", "-n", "vm.loadavg"]), "power": capture(["pmset", "-g", "ps"]),
            "thermal_pressure": capture(["sysctl", "-n", "machdep.xcpm.cpu_thermal_level"])}


def write_config(path: Path, item: str, telemetry: bool, label: str) -> Path:
    manifest = ROOT / "datasets/fixtures/generated-large/manifest.json"
    path.write_text(f"""schema_version: "1.0"
experiment_name: characterize-{label}
dataset:
  manifest_path: {manifest}
  item_id: {item}
audio:
  target_sample_rate_hz: 16000
  downmix_policy: arithmetic_mean_v1
  conversion_policy: apple_normal_max_half_up_v1
  endpoint_policy: allow_one_frame_v1
replay:
  mode: realtime
  frame_ms: 20
  speed: null
  queue_capacity: 32
  overflow: block
adapters:
  asr: {{id: mock-asr-scripted, revision: "1", delay_ms: 0}}
  diarization: {{id: mock-diar-scripted, revision: "1", delay_ms: 0}}
seed: 42
scoring:
  references: required
  text_policy: nfc_casefold_punct_space_cp_v1
  diarization_policy: pyannote_c0_overlap_uem_v1
telemetry:
  enabled: {"true" if telemetry else "false"}
  interval_ms: 1000
runtime:
  python_executable: {ROOT / ".venv/bin/python"}
  cleanup_timeout_s: 5
  analysis_timeout_s: 600
  max_output_bytes: 1073741824
notes:
  warm_state: not_applicable_mock
  background_load: uncontrolled agent-session host; see characterization host_conditions
""", encoding="utf-8")
    return path


def run(vb: str, config: Path, runs: Path, run_id: str) -> dict:
    before = host_conditions()
    result = subprocess.run([vb, "run", "--config", str(config), "--runs-dir", str(runs), "--run-id", run_id],
                            capture_output=True, text=True, timeout=7200, check=False)
    after = host_conditions()
    print(f"  {run_id}: exit {result.returncode}", flush=True)
    return {"run_id": run_id, "exit_code": result.returncode, "stderr_tail": result.stderr[-2000:],
            "host_before": before, "host_after": after, "path": str(runs / run_id)}


def metric(run_dir: Path, group: str, key: str) -> dict:
    return json.loads((run_dir / "metrics.json").read_text())[group][key]


def deadline_errors(run_dir: Path) -> list[tuple[float, int]]:
    summary = json.loads((run_dir / "runtime_summary.json").read_text())
    events = read_trace(run_dir / "events.jsonl", summary["events_prefix"]["byte_count"]).events
    rate = summary["replay"]["sample_rate_hz"]
    ends = {e["payload"]["chunk_index"]: e["payload"]["end_sample"] for e in events if e["type"] == "audio.chunk_scheduled"}
    return [(ends[e["payload"]["chunk_index"]] / rate, e["payload"]["deadline_error_ns"])
            for e in events if e["type"] == "audio.chunk_delivered"]


def fit(points: list[tuple[float, int]]) -> dict:
    n = len(points)
    mx = sum(p[0] for p in points) / n
    my = sum(p[1] for p in points) / n
    sxx = sum((p[0] - mx) ** 2 for p in points)
    slope = sum((p[0] - mx) * (p[1] - my) for p in points) / sxx if sxx else 0.0
    return {"method": "ordinary least squares of signed admission error (ns) on media time (s)",
            "slope_ns_per_media_second": slope, "intercept_ns": my - slope * mx, "n": n}


def dist(metric_record: dict) -> dict:
    return {k: metric_record.get(k) for k in ("status", "n", "p50", "p95", "min", "max", "reason", "exclusions")}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicebench", required=True)
    parser.add_argument("--realtime-seconds", type=int, default=60)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmup-seconds", type=int, default=10)
    parser.add_argument("--drift-seconds", type=int, default=720)
    parser.add_argument("--overhead-seconds", type=int, default=30)
    parser.add_argument("--overhead-pairs", type=int, default=3)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.warmup_seconds != 10:
        parser.error("the analysis warm-up exclusion is fixed at 10 s of media (DEC-061)")
    vb = str(Path(args.voicebench).resolve())
    out = Path(args.out).resolve()
    if out.exists():
        parser.error(f"{out} already exists; choose a new --out (existing output is never deleted)")
    (out / "configs").mkdir(parents=True)
    runs = out / "runs"
    for seconds in (args.realtime_seconds, args.drift_seconds, args.overhead_seconds):
        if not (ROOT / f"datasets/fixtures/generated-large/long_{seconds}s_16k_pcm16.wav").exists():
            parser.error(f"generate the {seconds}s item first: scripts/generate_fixtures.py --long-seconds {seconds} "
                         "--out datasets/fixtures/generated-large")
    report: dict = {"created": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
                    "voicebench": vb, "machine": {"platform": platform.platform(),
                                                  "model": capture(["sysctl", "-n", "hw.model"]),
                                                  "chip": capture(["sysctl", "-n", "machdep.cpu.brand_string"]),
                                                  "memory_bytes": capture(["sysctl", "-n", "hw.memsize"])},
                    "controlled_idle_host": False,
                    "host_note": "Runs executed from an agent session on the developer's machine; idle state, other "
                                 "processes and power settings were not controlled. Load averages and power source "
                                 "are recorded around every run.",
                    "runs": []}

    print("P01", flush=True)
    p01_config = write_config(out / "configs/p01.yaml", f"long-{args.realtime_seconds}s", True, "p01")
    p01 = []
    for n in range(args.repeats):
        r = run(vb, p01_config, runs, f"p01-{n + 1}")
        report["runs"].append(r)
        if r["exit_code"] == 0:
            d = Path(r["path"])
            p01.append({"run_id": r["run_id"], "full_signed": dist(metric(d, "timing", "delivery_jitter_ns")),
                        "full_absolute": dist(metric(d, "timing", "absolute_scheduling_error_ns")),
                        "post_warmup_absolute": dist(metric(d, "timing", "absolute_scheduling_error_post_warmup_ns")),
                        "wake_error": dist(metric(d, "timing", "scheduler_wake_error_ns")),
                        "dropped_samples": metric(d, "data_integrity", "dropped_samples")["value"],
                        "clock_minimum_resolution_ns": json.loads((d / "runtime_summary.json").read_text())["clock"]["minimum_resolution_ns"]})
    met = [p["post_warmup_absolute"]["p95"] is not None and p["post_warmup_absolute"]["p95"] <= TARGET_P95_NS for p in p01]
    report["P01"] = {"target": "post-warm-up absolute admission error p95 <= 20 ms (investigatory)",
                     "runs": p01, "completed_runs": len(p01), "requested_runs": args.repeats,
                     "target_met_all_runs": bool(p01) and all(met) and len(p01) == args.repeats}

    print("P02", flush=True)
    r = run(vb, write_config(out / "configs/p02.yaml", f"long-{args.drift_seconds}s", True, "p02"), runs, "p02-drift")
    report["runs"].append(r)
    if r["exit_code"] == 0:
        d = Path(r["path"])
        summary = json.loads((d / "runtime_summary.json").read_text())
        points = deadline_errors(d)
        expected = args.drift_seconds * 16_000
        cov = summary["coverage"]
        exact = (cov["produced_samples"] == cov["consumed_samples"] == expected and cov["dropped_samples"] == 0
                 and summary["integrity"]["end_of_stream_verified"] and len(points) == expected // 320)
        (out / "p02_drift.csv").write_text("media_time_s,signed_admission_error_ns\n" +
                                           "".join(f"{t},{e}\n" for t, e in points))
        trend = fit(points)
        report["P02"] = {"media_clock_exact": exact, "expected_samples": expected, "coverage": cov,
                         "chunks": len(points), "final_deviation_ns": points[-1][1] if points else None,
                         "max_abs_deviation_ns": max(abs(e) for _, e in points) if points else None,
                         "trend": trend, "post_warmup_absolute": dist(metric(d, "timing", "absolute_scheduling_error_post_warmup_ns")),
                         "note": "No universal wall-drift tolerance is asserted; exact sample accounting is the correctness criterion."}
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, ax = plt.subplots(figsize=(9, 4))
            ax.plot([p[0] for p in points], [p[1] / 1e6 for p in points], ".", markersize=1)
            xs = [points[0][0], points[-1][0]]
            ax.plot(xs, [(trend["intercept_ns"] + trend["slope_ns_per_media_second"] * x) / 1e6 for x in xs], "r-",
                    label=f"OLS trend {trend['slope_ns_per_media_second']:.1f} ns/s")
            ax.set_xlabel("media time (s)")
            ax.set_ylabel("signed admission error (ms)")
            ax.set_title(f"P02 {args.drift_seconds} s real-time replay, n={len(points)} chunks (MOCK adapters, uncontrolled host)",
                         fontsize=9)
            ax.legend(fontsize=8)
            fig.tight_layout()
            fig.savefig(out / "p02_drift.png", dpi=110)
            plt.close(fig)
        except Exception as exc:  # the plot is evidence, not a correctness check
            report["P02"]["plot_error"] = str(exc)
    else:
        report["P02"] = {"media_clock_exact": False, "error": r["stderr_tail"]}

    print("P03", flush=True)
    on_cfg = write_config(out / "configs/p03-on.yaml", f"long-{args.overhead_seconds}s", True, "p03-on")
    off_cfg = write_config(out / "configs/p03-off.yaml", f"long-{args.overhead_seconds}s", False, "p03-off")
    pairs = []
    for n in range(args.overhead_pairs):
        order = [("on", on_cfg), ("off", off_cfg)] if n % 2 == 0 else [("off", off_cfg), ("on", on_cfg)]
        pair = {"pair": n + 1, "order": [o for o, _ in order]}
        for label, cfg in order:
            r = run(vb, cfg, runs, f"p03-{n + 1}-{label}")
            report["runs"].append(r)
            if r["exit_code"] == 0:
                d = Path(r["path"])
                summary = json.loads((d / "runtime_summary.json").read_text())
                pair[label] = {"run_id": r["run_id"], "runtime_total_ns": summary["durations_ns"]["runtime_total"],
                               "replay_elapsed_ns": summary["replay"]["elapsed_ns"], "recorder": summary["recorder"],
                               "telemetry_collection_ns": summary["durations_ns"].get("telemetry_collection"),
                               "post_warmup_absolute": dist(metric(d, "timing", "absolute_scheduling_error_post_warmup_ns")),
                               "cpu_percent": dist(metric(d, "resources", "cpu_percent"))}
        pairs.append(pair)
    report["P03"] = {"pairs": pairs, "note": "Raw paired results; three pairs support no significance claim and no "
                                             "overhead is subtracted from any measurement."}

    print("P04", flush=True)
    p04 = []
    for r in report["runs"]:
        d = Path(r["path"])
        if r["exit_code"] != 0 or not (d / "runtime_summary.json").exists():
            continue
        summary = json.loads((d / "runtime_summary.json").read_text())
        if summary["telemetry"] is None:
            continue
        resources = json.loads((d / "metrics.json").read_text())["resources"]
        p04.append({"run_id": r["run_id"], "sampler": summary["telemetry_sampler"],
                    "cpu_percent": dist(resources["cpu_percent"]), "rss_peak_sampled_bytes": resources["rss_peak_sampled_bytes"]["value"],
                    "statuses": {k: v["status"] for k, v in resources.items()}})
    report["P04"] = {"runs": p04, "cpu_and_rss_present_in_all": bool(p04) and all(
        p["cpu_percent"]["status"] == "ok" and p["rss_peak_sampled_bytes"] is not None for p in p04)}
    report["all_runs_succeeded"] = all(r["exit_code"] == 0 for r in report["runs"])
    (out / "characterization.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"characterize: runs ok={report['all_runs_succeeded']}, P01 target met={report['P01']['target_met_all_runs']}, "
          f"P02 exact={report['P02'].get('media_clock_exact')}, P04 cpu/rss={report['P04']['cpu_and_rss_present_in_all']}")
    return 0 if report["all_runs_succeeded"] else 1


if __name__ == "__main__":
    sys.exit(main())
