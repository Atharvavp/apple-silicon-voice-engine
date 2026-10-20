#!/usr/bin/env python3
"""Phase 1 report: per-run table, three-run summaries, up to three plots and the findings report.

    .venv/bin/python scripts/report_phase1.py --campaign "$SESSION/campaign" --datasets "$SESSION/datasets" \
        --protected "$SESSION/snapshot-end.json" --out "$SESSION/report"

Only sealed runs that pass `voicebench validate --run` AND the Phase 1 eligibility checks below
enter the tables: active role/model/revision as frozen in matrix.json, passive counterpart,
frozen input/reference hashes, the active role's reference actually scored, no data loss,
the frozen replay policy, exact/bypassed endpoints, no mock. Everything else stays listed
with its reasons and is never ranked. Comparisons are `best_practical` unless matched-model
equivalence evidence exists (it never does by default). Legacy `voicebench compare` is not used.
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ROWS = {"D1": ("diarization", "fluid"), "D2": ("diarization", "speech"),
        "A1": ("asr", "fluid"), "A2": ("asr", "speech")}
PASSIVE_IDS = {"passive-asr", "passive-diar"}
FRAMEWORK_NAMES = {"fluid": "FluidAudio", "speech": "speech-swift"}
REQUIRED_REPEATS = 3


def load(path: Path) -> Any:
    return json.loads(path.read_text())


def metric(group: dict, key: str) -> float | None:
    record = group.get(key) or {}
    return record.get("value") if record.get("status") == "ok" else None


def distribution(group: dict, key: str) -> dict[str, Any]:
    record = group.get(key) or {}
    if record.get("status") != "ok":
        return {"p50": None, "p95": None, "n": record.get("n", 0), "status": record.get("status", "missing")}
    return {"p50": record["p50"], "p95": record["p95"], "n": record["n"], "status": "ok"}


def stage_durations(events_path: Path) -> dict[str, int]:
    totals: dict[str, int] = {}
    with events_path.open() as handle:
        for line in handle:
            if '"stage.completed"' not in line:
                continue
            event = json.loads(line)
            if event["type"] == "stage.completed":
                name = event["payload"]["stage"]
                totals[name] = totals.get(name, 0) + event["payload"]["duration_ns"]
    return totals


def eligibility(run: Path, row_id: str, matrix: dict, ami: dict, ledger_entry: dict) -> tuple[list[str], dict]:
    """Reasons a run may not enter the comparison tables (empty = eligible)."""
    reasons: list[str] = []
    facts: dict[str, Any] = {}
    role, _ = ROWS[row_id]
    frozen = matrix["rows"].get(row_id)
    if frozen is None:
        return [f"{row_id} is not in the frozen matrix"], facts
    status = load(run / "status.json") if (run / "status.json").exists() else {}
    if status.get("state") != "completed":
        reasons.append(f"run state {status.get('state')!r}, not completed/sealed")
        return reasons, facts
    if ledger_entry.get("validate_exit_code") != 0:
        reasons.append(f"voicebench validate --run exit {ledger_entry.get('validate_exit_code')}")
    metrics, config = load(run / "metrics.json"), load(run / "config.json")
    summary = load(run / "runtime_summary.json")
    facts.update(metrics=metrics, config=config, summary=summary)
    if metrics.get("mock") is not False:
        reasons.append("mock adapters")
    adapters = config["settings"]["adapters"]
    other = "asr" if role == "diarization" else "diarization"
    if adapters[role]["id"] != frozen["adapter_id"] or adapters[role]["revision"] != frozen["revision"]:
        reasons.append(f"active {role} adapter {adapters[role]} differs from the frozen {frozen['adapter_id']} {frozen['revision']}")
    if adapters[other]["id"] not in PASSIVE_IDS:
        reasons.append(f"counterpart {other} role is {adapters[other]['id']}, not passive")
    inputs = config["inputs"]
    if inputs.get("audio_sha256") != ami.get("crop", {}).get("sha256") or inputs.get("item_id") != ami.get("item_id"):
        reasons.append("audio/item differs from the frozen AMI crop")
    ref = ami.get("references", {}).get("transcript" if role == "asr" else "speakers", {})
    expected = (f"{ref.get('sha256') or '-'}\n-\n" if role == "asr" else f"-\n{ref.get('sha256') or '-'}\n")
    import hashlib
    if inputs.get("reference_sha256") != hashlib.sha256(expected.encode()).hexdigest():
        reasons.append("reference descriptor differs from the frozen role reference")
    primary = ("wer", "cer") if role == "asr" else ("der", "jer")
    for key in primary:
        if metrics["accuracy"][key]["status"] != "ok":
            reasons.append(f"{key} not computed ({metrics['accuracy'][key].get('reason')})")
    if summary.get("data_loss") or summary["coverage"]["dropped_samples"] != 0 or \
            summary["coverage"]["consumed_samples"] != summary["coverage"]["produced_samples"]:
        reasons.append("data loss or incomplete coverage")
    replay = config["settings"]["replay"]
    if (replay["mode"], replay["frame_ms"], replay["queue_capacity"], replay["overflow"]) != ("realtime", 20, 32, "block"):
        reasons.append(f"replay policy {replay} differs from the frozen realtime/20 ms/32/block")
    endpoint = summary["conversion"].get("endpoint_status")
    if endpoint not in ("bypassed", "exact"):
        reasons.append(f"endpoint correction {endpoint}")
    if config["settings"]["scoring"]["text_policy"] != "nfc_casefold_punct_space_cp_v1" or \
            config["settings"]["scoring"]["diarization_policy"] != "pyannote_c0_overlap_uem_v1":
        reasons.append("scoring policy differs from the frozen policies")
    return reasons, facts


def run_row(run: Path, row_id: str, entry: dict, facts: dict, reasons: list[str]) -> dict[str, Any]:
    role, framework = ROWS[row_id]
    out: dict[str, Any] = {"run_id": entry["run_id"], "row": row_id, "framework": FRAMEWORK_NAMES[framework], "role": role,
                           "repetition": entry.get("repetition"), "eligible": not reasons, "reasons": "; ".join(reasons),
                           "ledger_status": entry.get("status"), "exit_code": entry.get("exit_code"),
                           "stopped_by_supervisor": entry.get("stopped_by_supervisor"),
                           "observed_peak_rss_bytes_supervisor": entry.get("observed_peak_rss_bytes")}
    if not facts:
        return out
    metrics, summary = facts["metrics"], facts["summary"]
    accuracy, timing, throughput, resources = (metrics["accuracy"], metrics["timing"], metrics["throughput"],
                                               metrics["resources"])
    stages = stage_durations(run / "events.jsonl")
    phases = {p["phase"]: p["end_ns"] - p["start_ns"] for p in summary["phases"]}
    active_ns = stages.get(f"{role}.consume", 0) + stages.get(f"{role}.flush", 0)
    out.update({
        "wer": metric(accuracy, "wer"), "cer": metric(accuracy, "cer"), "der": metric(accuracy, "der"),
        "jer": metric(accuracy, "jer"),
        "setup_s": phases.get("adapter_prepare", 0) / 1e9,
        "active_processing_s": active_ns / 1e9, "active_flush_s": stages.get(f"{role}.flush", 0) / 1e9,
        "passive_overhead_s": (stages.get(f"{'asr' if role == 'diarization' else 'diarization'}.consume", 0)
                               + stages.get(f"{'asr' if role == 'diarization' else 'diarization'}.flush", 0)) / 1e9,
        "adapter_service_rtf": metric(throughput, "adapter_service_rtf"), "replay_rtf": metric(throughput, "replay_rtf"),
        "end_to_end_rtf": metric(throughput, "end_to_end_rtf"),
        "rss_peak_sampled_mib": (metric(resources, "rss_peak_sampled_bytes") or 0) / 2**20 or None,
    })
    for key in (f"{role}_consume_ns", "event_emission_latency_ns", "delivery_to_output_latency_ns"):
        d = distribution(timing, key)
        out[f"{key}_p50"], out[f"{key}_p95"], out[f"{key}_n"] = d["p50"], d["p95"], d["n"]
    return out


SUMMARY_KEYS = ["wer", "cer", "der", "jer", "setup_s", "active_processing_s", "active_flush_s", "adapter_service_rtf",
                "replay_rtf", "rss_peak_sampled_mib"]


def summarize(rows: list[dict]) -> dict[str, dict]:
    """Three-run median [min, max] per row, eligible runs only. No pooled percentiles."""
    out: dict[str, dict] = {}
    for row_id in ROWS:
        valid = [r for r in rows if r["row"] == row_id and r["eligible"]]
        record: dict[str, Any] = {"valid_n": len(valid), "attempts": sum(1 for r in rows if r["row"] == row_id)}
        for key in SUMMARY_KEYS:
            values = [r[key] for r in valid if r.get(key) is not None]
            record[key] = ({"median": statistics.median(values), "min": min(values), "max": max(values), "n": len(values)}
                           if values else None)
        out[row_id] = record
    return out


def classify(summary: dict, matrix: dict) -> dict[str, dict]:
    """Pairs are best_practical: different conversions/precision/post-processing; no equivalence evidence."""
    pairs = {}
    for role, (a, b) in {"diarization": ("D1", "D2"), "asr": ("A1", "A2")}.items():
        both = summary[a]["valid_n"] > 0 and summary[b]["valid_n"] > 0
        pairs[role] = {"rows": [a, b], "classification": "best_practical" if both else "not_comparable",
                       "matched_model_evidence": None,
                       "differences": (["different CoreML conversions/repositories of the same NVIDIA checkpoint family",
                                        "Fluid FP16 low-context export vs speech-swift streaming export",
                                        "different post-processing (Fluid pass-through 0.5 thresholds vs speech 0.3 s "
                                        "minimum speech / 0.15 s gap merge)",
                                        "speech-swift compacts speaker IDs in its final snapshot"]
                                       if role == "diarization" else
                                       ["Fluid 320 ms FP16-storage conversion vs speech-swift INT8-palettized encoder",
                                        "same declared chunk geometry (64 mel frames, 4 output frames, 5120-sample shift) "
                                        "but separate mel/RNNT decoder implementations",
                                        "different transcript assembly (cumulative decode vs EOU-segmented finals; speech "
                                        "suppresses consecutive identical finals natively)"])
                       + (["separate per-framework binaries"] if len({v.get('binary_sha256') for k, v in
                                                                     matrix['rows'].items() if k in (a, b)}) > 1 else [])}
    return pairs


def overall_status(summary: dict, protected: dict | None) -> str:
    if protected is not None and protected.get("comparison", {}).get("status") != "pass":
        return "INVALID"
    if all(summary[r]["valid_n"] == 0 for r in ROWS):
        return "NOT_RUN"
    if all(summary[r]["valid_n"] >= REQUIRED_REPEATS for r in ROWS):
        return "COMPLETE"
    return "PARTIAL"


def fmt(value: Any, digits: int = 3) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, dict):
        return f"{value['median']:.{digits}f} [{value['min']:.{digits}f}, {value['max']:.{digits}f}] (n={value['n']})"
    return f"{value:.{digits}f}" if isinstance(value, float) else str(value)


def plots(summary: dict, out: Path) -> list[str]:
    """At most three figures; nothing is drawn without eligible data."""
    if all(summary[r]["valid_n"] == 0 for r in ROWS):
        return []
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    made = []
    specs = [("accuracy.png", "Accuracy by role (lower is better)", [("A1", "wer"), ("A2", "wer"), ("D1", "der"), ("D2", "der")], "ratio"),
             ("service_time.png", "Active-role processing time", [(r, "active_processing_s") for r in ROWS], "seconds"),
             ("memory.png", "Sampled peak RSS (runner process)", [(r, "rss_peak_sampled_mib") for r in ROWS], "MiB")]
    for name, title, series, unit in specs:
        labels, medians, errors = [], [], [[], []]
        for row_id, key in series:
            value = summary[row_id].get(key)
            labels.append(f"{row_id} {key}" + ("" if value else " (missing)"))
            medians.append(value["median"] if value else 0)
            errors[0].append(value["median"] - value["min"] if value else 0)
            errors[1].append(value["max"] - value["median"] if value else 0)
        figure, axis = plt.subplots(figsize=(7, 3.5))
        axis.bar(labels, medians, yerr=errors, capsize=4, color="#4C72B0")
        axis.set_title(title + " — median with min–max across eligible runs")
        axis.set_ylabel(unit)
        axis.tick_params(axis="x", labelrotation=15)
        figure.tight_layout()
        figure.savefig(out / name, dpi=120)
        plt.close(figure)
        made.append(name)
    return made


def write_csv(path: Path, rows: list[dict]) -> None:
    keys = sorted({k for r in rows for k in r}) if rows else ["run_id"]
    with path.open("x", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys)
        writer.writeheader()
        writer.writerows(rows)


def markdown(status: str, context: dict, summary: dict, pairs: dict, runs: list[dict], figures: list[str]) -> str:
    blocked = context["blocked"]
    lines = [
        "# FluidAudio vs speech-swift on an M5 MacBook Air: English ASR and Sortformer", "",
        f"Status: **{status}**", "",
        f"Generated {time.strftime('%Y-%m-%d %H:%M %z')} by `scripts/report_phase1.py` from `{context['campaign']}`.",
        f"Repository: `{context['git']}`; schema bundle `{context['schema']}`; Package.resolved `{context['lock']}`.",
        "", "## Question and setup", "",
        "Which on-device Swift framework gives better English streaming ASR (Parakeet EOU 120M) and streaming",
        "Sortformer v2.1 diarization on this machine, under one fresh process per run, real-time 1x replay with",
        "20 ms frames, one active model and a passive counterpart role? Requested Core ML compute units: `all`;",
        "observed placement: unavailable (no public per-model observation). Three repetitions were planned per row.",
        "", "## Rows", "",
        "| Row | Framework / configuration | Role | Valid n | Attempts | Status |",
        "|---|---|---|---:|---:|---|",
    ]
    names = {"D1": "FluidAudio Sortformer v2.1 low-context (FP16)", "D2": "speech-swift Sortformer v2.1 streaming",
             "A1": "FluidAudio Parakeet EOU 120M 320 ms", "A2": "speech-swift Parakeet EOU 120M INT8"}
    for row_id, (role, _) in ROWS.items():
        state = "blocked: " + blocked[row_id] if row_id in blocked else (
            "complete" if summary[row_id]["valid_n"] >= REQUIRED_REPEATS else
            "partial repeatability" if summary[row_id]["valid_n"] else "no valid runs")
        lines.append(f"| {row_id} | {names[row_id]} | {role} | {summary[row_id]['valid_n']} | "
                     f"{summary[row_id]['attempts']} | {state} |")
    lines += ["", f"Optional VoxConverse: {context['vox']}.", "", "## Results", ""]
    if status == "NOT_RUN":
        lines += ["No measured run could start, so there are no accuracy, time or memory results. The rows above",
                  "list the missing prerequisites; nothing below this line is a measurement.", ""]
    else:
        lines += ["Median [min, max] across eligible runs (fractions, not percentages).", "",
                  "| Row | Valid n | WER | CER | DER | JER |", "|---|---:|---:|---:|---:|---:|"]
        for row_id in ROWS:
            s = summary[row_id]
            lines.append(f"| {row_id} | {s['valid_n']} | {fmt(s['wer'])} | {fmt(s['cer'])} | {fmt(s['der'])} | {fmt(s['jer'])} |")
        lines += ["", "| Row | Setup s | Active-role processing s | Service RTF | Replay RTF | Sampled peak RSS MiB |",
                  "|---|---:|---:|---:|---:|---:|"]
        for row_id in ROWS:
            s = summary[row_id]
            lines.append(f"| {row_id} | {fmt(s['setup_s'])} | {fmt(s['active_processing_s'])} | "
                         f"{fmt(s['adapter_service_rtf'], 4)} | {fmt(s['replay_rtf'], 4)} | {fmt(s['rss_peak_sampled_mib'], 1)} |")
        lines += ["", "Per-run values, including ASR consume and event-timing p50/p95/n, are in `results-per-run.csv`.",
                  "Paced replay RTF near 1 is not compute speed. Service RTF includes the passive role's calls.",
                  "ASR event timings are wrapper invocation/delivery timings, not word latency. Final-only speaker",
                  "output has no online label latency (not computable). Compute-only RTF and time-to-first-word are",
                  "not computable; GPU/ANE/power are unsupported.", ""]
        for name in figures:
            lines.append(f"![{name}]({name})")
    lines += ["", "## Comparison boundaries", ""]
    for role, pair in pairs.items():
        lines.append(f"- **{role}** ({' vs '.join(pair['rows'])}): `{pair['classification']}`. Differences: "
                     + "; ".join(pair["differences"]) + ".")
    lines += ["", "## Failures and limitations", ""]
    failed = [r for r in runs if not r["eligible"]]
    if not runs:
        lines.append("- No measured attempts exist.")
    for r in failed:
        lines.append(f"- `{r['run_id']}` ({r['row']}): not eligible — {r['reasons'] or r['ledger_status']}.")
    lines += context["limitations"]
    lines += ["", "## Draft LinkedIn case-study summary", ""]
    if status in ("COMPLETE", "PARTIAL") and any(summary[r]["valid_n"] for r in ROWS):
        lines.append("Draft only after owner review of the tables above; cite only numbers that appear there.")
    else:
        lines.append("Withheld: there are no measured results to report. A post now could only describe the harness.")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--campaign", required=True)
    parser.add_argument("--datasets", required=True)
    parser.add_argument("--protected", help="output of `run_phase1.py verify` (end-of-session protected check)")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    campaign, out = Path(args.campaign), Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    summary_doc = load(campaign / "campaign-summary.json") if (campaign / "campaign-summary.json").exists() else {}
    matrix = load(campaign / "matrix.json") if (campaign / "matrix.json").exists() else {"rows": {}, "blocked": {}}
    ledger = [json.loads(line) for line in (campaign / "ledger.jsonl").read_text().splitlines()] \
        if (campaign / "ledger.jsonl").exists() else []
    freeze_path = Path(args.datasets) / "dataset-freeze.json"
    freeze = load(freeze_path) if freeze_path.exists() else {"datasets": {}}
    ami = freeze["datasets"].get("ami", {})
    protected = load(Path(args.protected)) if args.protected else None

    runs = []
    for entry in (e for e in ledger if e.get("kind") == "measured"):
        run = campaign / "runs" / entry["run_id"]
        reasons, facts = (eligibility(run, entry["row"], matrix, ami, entry) if run.is_dir()
                          else ([f"no run directory ({entry.get('status')})"], {}))
        runs.append(run_row(run, entry["row"], entry, facts, reasons))
    summary = summarize(runs)
    pairs = classify(summary, matrix)
    status = overall_status(summary, protected)
    blocked = {**matrix.get("blocked", {}), **summary_doc.get("blocked", {})}
    git_head = (protected or {}).get("snapshot", {}).get("git", {})
    vox = freeze["datasets"].get("voxconverse", {"status": "skipped_optional", "reason": "dataset stage not run"})
    limitations = [
        "- AMI references are frozen projections: recording-text linearization of manual words (not speaker-attributed "
        "WER) and derived word-union speaker activity (not standard AMI segmentation).",
        "- Sortformer and Parakeet training data may include AMI; this is not an unseen-holdout result.",
        "- RSS is the runner process's sampled resident size, not total unified memory; brief peaks can be missed.",
        "- One machine, one crop, three repetitions: repeatability evidence only, no significance claim.",
    ]
    context = {"campaign": str(campaign), "blocked": blocked, "vox": f"{vox.get('status')} ({vox.get('reason', '')})",
               "git": f"{git_head.get('head', 'unknown')} {'dirty' if git_head.get('porcelain') else 'clean'}",
               "schema": (protected or {}).get("snapshot", {}).get("schema_bundle", {}).get("sha256", "unknown"),
               "lock": summary_doc.get("package_resolved_sha256", "unknown"), "limitations": limitations}
    figures = plots(summary, out)
    write_csv(out / "results-per-run.csv", runs)
    write_csv(out / "results-summary.csv", [{"row": k, **{m: fmt(v.get(m)) if m != "valid_n" else v["valid_n"]
                                                          for m in ["valid_n", *SUMMARY_KEYS]}} for k, v in summary.items()])
    report = {"status": status, "summary": summary, "pairs": pairs, "blocked": blocked, "figures": figures,
              "runs": len(runs), "eligible_runs": sum(r["eligible"] for r in runs)}
    with (out / "report.json").open("x") as handle:
        json.dump(report, handle, indent=2, default=str)
    (out / "PHASE_1_RESULTS.md").open("x").write(markdown(status, context, summary, pairs, runs, figures))
    print(json.dumps({"status": status, "eligible_runs": report["eligible_runs"], "runs": len(runs)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
