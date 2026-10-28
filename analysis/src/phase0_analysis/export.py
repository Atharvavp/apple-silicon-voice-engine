"""``export``: tidy CSVs and PNG plots of one run into a new directory (plan M6).

Missing values stay blank *and* carry their status and reason; nothing is
written as 0. Every plot names the run, units, sample count and the mock label.
Plots never render transcript text (no font dependency for Devanagari); CSVs
keep full Unicode. Nothing in the run directory is modified.
"""

from __future__ import annotations

import csv
import io
from pathlib import Path
from typing import Any

from .schemas import load_strict, loads_strict
from .trace import read_trace


def _csv(rows: list[list[Any]], header: list[str]) -> str:
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(header)
    writer.writerows(rows)
    return out.getvalue()


def metrics_csv(metrics: dict[str, Any], config: dict[str, Any]) -> str:
    rows = []
    for group in ("accuracy", "timing", "throughput", "resources", "data_integrity"):
        for key, m in metrics[group].items():
            distribution = "p95" in m
            value = m["p50"] if distribution else m["value"]
            rows.append([metrics["run_id"], metrics["source_id"], metrics["mock"], config["settings"]["replay"]["mode"],
                         group, key, m["status"], "" if value is None else repr(value),
                         "" if not distribution or m["p95"] is None else repr(m["p95"]),
                         m["n"] if distribution else m["sample_count"], m["unit"], m["definition_id"],
                         m["clock_domain"], m["reason"] or "", metrics["policies"]["text"],
                         metrics["policies"]["diarization"]])
    return _csv(rows, ["run_id", "source_id", "mock", "replay_mode", "group", "metric", "status", "value_or_p50", "p95",
                       "n", "unit", "definition_id", "clock_domain", "reason", "text_policy", "diarization_policy"])


def predictions_csv(predictions: dict[str, Any]) -> str:
    rows = [["transcript", t["utterance_id"], "", t["start_sample"], t["end_sample"], t["text"], ";".join(t["event_ids"])]
            for t in predictions["transcript"]]
    rows += [["speaker", s["segment_id"], s["speaker_id"], s["start_sample"], s["end_sample"], "", ";".join(s["event_ids"])]
             for s in predictions["speakers"]]
    return _csv(rows, ["kind", "id", "speaker_id", "start_sample", "end_sample", "text", "event_ids"])


def chunk_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    chunks: dict[int, dict[str, Any]] = {}
    for e in events:
        if e["type"] in ("audio.chunk_scheduled", "audio.chunk_delivered", "audio.chunk_consumed", "audio.queue_overflow"):
            row = chunks.setdefault(e["payload"]["chunk_index"], {"outcome": "pending"})
            row.update({k: v for k, v in e["payload"].items() if k not in ("invocation_ids", "policy")})
            if e["type"] == "audio.chunk_delivered":
                row["outcome"] = "accepted"
            if e["type"] == "audio.queue_overflow":
                row["outcome"] = "dropped"
    return [chunks[i] for i in sorted(chunks)]


TIMING_FIELDS = ["chunk_index", "start_sample", "end_sample", "outcome", "planned_deadline_ns", "media_deadline_virtual_ns",
                 "offer_ns", "entry_ns", "wake_error_ns", "deadline_error_ns", "queue_depth", "dequeue_ns", "finish_ns",
                 "delivered_virtual_ns", "lost_samples"]


def timing_csv(rows: list[dict[str, Any]]) -> str:
    return _csv([["" if r.get(f) is None else r.get(f) for f in TIMING_FIELDS] for r in rows], TIMING_FIELDS)


def resources_csv(samples: list[dict[str, Any]]) -> str:
    keys = sorted({k for s in samples for k in s["measurements"]})
    rows = []
    for s in samples:
        row = [s["sample_id"], s["phase"], s["measured_ns"], "" if s["interval_ns"] is None else s["interval_ns"]]
        for key in keys:
            m = s["measurements"].get(key)
            row += ["", "missing", ""] if m is None else ["" if m["value"] is None else m["value"], m["status"],
                                                           m["reason"] or ""]
        rows.append(row)
    header = ["sample_id", "phase", "measured_ns", "interval_ns"]
    for key in keys:
        header += [key, f"{key}.status", f"{key}.reason"]
    return _csv(rows, header)


def loss_csv(summary: dict[str, Any]) -> str:
    return _csv([[r["start_sample"], r["end_sample"], r["end_sample"] - r["start_sample"]]
                 for r in summary["coverage"]["dropped_ranges"]], ["start_sample", "end_sample", "lost_samples"])


def plots(out: Path, run_id: str, mock: bool, summary: dict[str, Any], rows: list[dict[str, Any]],
          events: list[dict[str, Any]], samples: list[dict[str, Any]] | None) -> list[str]:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    label = f"run {run_id}{' (MOCK adapters)' if mock else ''}"
    rate = summary["replay"]["sample_rate_hz"]
    written = []

    def save(fig: Any, name: str) -> None:
        fig.tight_layout()
        fig.savefig(out / name, dpi=110)
        plt.close(fig)
        written.append(name)

    def empty(ax: Any, message: str) -> None:
        ax.text(0.5, 0.5, message, ha="center", va="center", transform=ax.transAxes, wrap=True)
        ax.set_xticks([])
        ax.set_yticks([])

    fig, ax = plt.subplots(figsize=(8, 4))
    points = [(r["end_sample"] / rate, r["deadline_error_ns"] / 1e6) for r in rows if r.get("deadline_error_ns") is not None]
    if points:
        ax.plot([p[0] for p in points], [p[1] for p in points], ".", markersize=2)
        ax.axhline(0, color="gray", linewidth=0.5)
        ax.set_xlabel("media time (s)")
        ax.set_ylabel("signed admission error (ms)")
    else:
        empty(ax, f"no real deadlines ({summary['replay']['mode']} mode): scheduling error is not computable")
    ax.set_title(f"Delivery jitter vs media time, n={len(points)} — {label}", fontsize=9)
    save(fig, "jitter_vs_media_time.png")

    fig, ax = plt.subplots(figsize=(8, 4))
    stages = {}
    for e in events:
        if e["type"] == "stage.completed" and e["payload"]["stage"].endswith(".consume"):
            stages.setdefault(e["payload"]["stage"], []).append(e["payload"]["duration_ns"] / 1e3)
    if stages:
        for name, values in sorted(stages.items()):
            ax.hist(values, bins=50, alpha=0.6, label=f"{name} (n={len(values)})")
        ax.set_xlabel("invocation duration (µs, real clock)")
        ax.set_ylabel("count")
        ax.legend(fontsize=8)
    else:
        empty(ax, "no adapter invocations recorded")
    ax.set_title(f"Adapter consume durations ({summary['replay']['mode']}) — {label}", fontsize=9)
    save(fig, "adapter_consume_durations.png")

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8, 5), sharex=True)
    if samples:
        t = [s["measured_ns"] / 1e9 for s in samples]
        cpu = [(s["measured_ns"] / 1e9, s["measurements"]["cpu_percent"]["value"]) for s in samples
               if s["measurements"]["cpu_percent"]["status"] == "ok"]
        rss = [s["measurements"]["rss_bytes"]["value"] / 2**20 if s["measurements"]["rss_bytes"]["status"] == "ok"
               else float("nan") for s in samples]
        if cpu:
            ax1.plot([c[0] for c in cpu], [c[1] for c in cpu], "o-", markersize=3)
        ax1.set_ylabel("CPU % (one core)")
        ax2.plot(t, rss, "o-", markersize=3)
        ax2.set_ylabel("RSS (MiB)")
        ax2.set_xlabel("run time (s)")
        ax1.set_title(f"Runner process CPU and RSS, n={len(samples)} samples — {label}", fontsize=9)
    else:
        empty(ax1, "telemetry disabled: no samples")
        empty(ax2, "telemetry disabled: no samples")
    save(fig, "cpu_rss.png")
    return written


def export_run(run: Path, out: Path, fmt: str) -> list[str]:
    run, out = Path(run), Path(out)
    if out.exists() and any(out.iterdir()):
        raise FileExistsError(str(out))
    out.mkdir(parents=True, exist_ok=True)
    config = load_strict(run / "config.json")
    summary = load_strict(run / "runtime_summary.json")
    metrics = load_strict(run / "metrics.json")
    predictions = load_strict(run / "predictions.json")
    trace = run / "events.jsonl" if (run / "events.jsonl").exists() else run / "events.jsonl.partial"
    events = read_trace(trace, summary["events_prefix"]["byte_count"]).events
    samples = None
    if summary["telemetry"] is not None:
        samples = [loads_strict(line) for line in (run / summary["telemetry"]["path"]).read_bytes().splitlines()]
    rows = chunk_rows(events)
    written = []
    if fmt in ("csv", "all"):
        files = {"metrics.csv": metrics_csv(metrics, config), "predictions.csv": predictions_csv(predictions),
                 "timing.csv": timing_csv(rows), "resources.csv": resources_csv(samples or []),
                 "loss-ranges.csv": loss_csv(summary)}
        for name, text in files.items():
            with open(out / name, "x", encoding="utf-8") as handle:
                handle.write(text)
            written.append(name)
    if fmt in ("plots", "all"):
        written += plots(out, config["run_id"], metrics["mock"], summary, rows, events, samples)
    return written
