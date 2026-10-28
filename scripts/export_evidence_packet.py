#!/usr/bin/env python3
"""Build the small public evidence packet for one Phase 1 session; the original evidence is only read.

    .venv/bin/python scripts/export_evidence_packet.py \\
        --session evidence/phase1/one-shot/20261021-s2 --out docs/phase1/evidence/20261021-s2

Writes into a NEW directory (refused if it exists):
  * byte-identical copies of the approved aggregate files: report/results-per-run.csv,
    report/results-summary.csv, report/report.json and build/Package.resolved.both;
  * provenance.json: identities of host, toolchain, binary, locks, schema bundle, frameworks, model
    profiles (repository, revision, selected files and hashes), AMI input/crop/reference hashes and
    the per-run execution record. No absolute paths, transcript or speaker text, participant IDs,
    owner notes or raw power/thermal text are copied;
  * recomputation.json: per-run accuracy re-read from every metrics.json and the per-row summary
    re-derived (scripts/report_phase1.py arithmetic) and compared with the copied CSVs;
  * MANIFEST.sha256 for every written file, plus each copy's original path and SHA-256.

Audio, model weights, events/telemetry traces, predictions and references stay in the private
session directory; the packet is a provenance index, not a reproduction bundle.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COPIES = {"results-per-run.csv": "report/results-per-run.csv", "results-summary.csv": "report/results-summary.csv",
          "report.json": "report/report.json", "Package.resolved.both": "build/Package.resolved.both"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def report_module():
    spec = importlib.util.spec_from_file_location("report_phase1", ROOT / "scripts/report_phase1.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["report_phase1"] = module
    spec.loader.exec_module(module)
    return module


def profile_identity(path: Path) -> dict:
    profile = load(path)
    model = profile["model"]
    return {"adapter_id": profile["adapter_id"], "role": profile["role"], "profile_revision": "p1:" + sha256(path),
            "framework": profile["framework"], "compute_units_requested": profile["compute_units"],
            "settings": profile["settings"], "output": profile["output"],
            "model": {k: model[k] for k in ("repository", "revision", "precision", "load_path", "licenses")}
            | {"files": model["files"], "total_bytes": sum(f["bytes"] for f in model["files"])}}


def dataset_identity(freeze: dict) -> dict:
    ami = freeze["datasets"]["ami"]
    annotations = ami["annotations"]
    return {
        "source": "AMI Meeting Corpus, headset mix (CC BY 4.0); manual annotations " + annotations["version"],
        "meeting": ami["meeting"], "item_id": ami["item_id"], "status": ami["status"],
        "source_audio": {k: v for k, v in ami["source_audio"].items() if k != "path"},
        "crop": {k: v for k, v in ami["crop"].items() if k != "path"},
        "annotations": {"version": annotations["version"], "meetings_xml_sha256": annotations["meetings_xml_sha256"],
                        "words_files_sha256": annotations["words_files"], "speaker_count": len(annotations["speakers"])},
        "time_policy": ami["time_policy"],
        "references": {role: {k: v for k, v in ref.items() if k != "path"} for role, ref in ami["references"].items()},
        "nonlexical_handling": ami["nonlexical_handling"], "overlap_speech_seconds": ami["overlap_speech_seconds"],
        "acoustic_spot_check": ami["acoustic_spot_check"],
        "smoke_item": {"item_id": ami["smoke"]["item_id"], "sha256": ami["smoke"]["sha256"]},
        "voxconverse": freeze["datasets"].get("voxconverse", {}).get("status"),
    }


def host_identity(environments: list[dict]) -> dict:
    """Fields identical in every run; `git_dirty` is per run (see run records), not host identity."""
    keys = ("os", "arch", "hardware", "toolchain", "build")
    def projection(e: dict) -> dict:
        return {k: e[k] for k in keys} | {"build": {k: v for k, v in e["build"].items() if k != "git_dirty"}}
    if len({json.dumps(projection(e), sort_keys=True) for e in environments}) != 1:
        raise ValueError("measured runs disagree on host/toolchain/build identity")
    first = environments[0]
    python = first["python"]
    return projection(first) | {
        "python": {"version": python["version"], "lock_sha256": python["lock_sha256"]},
        "analysis_version": first["analysis_version"], "run_conditions": first["run_conditions"],
        "placement": first["placement"], "identical_across_runs": len(environments)}


def conditions(record: dict | None) -> dict | None:
    if not record:
        return None
    return {"loadavg": record.get("loadavg"), "memory_pressure_level": record.get("memory_pressure_level"),
            "ac_power": "AC Power" in (record.get("power") or "")}


def run_record(runs: Path, entry: dict, matrix_row: dict) -> dict:
    run = runs / entry["run_id"]
    status, summary, metrics = load(run / "status.json"), load(run / "runtime_summary.json"), load(run / "metrics.json")
    environment = load(run / "environment.json")
    derived = sorted(run.glob("derived/validation-*/validation.json"))
    digests = {a["path"]: a["sha256"] for a in status["artifacts"]}
    return {
        "run_id": entry["run_id"], "row": entry["row"], "repetition": entry["repetition"],
        "profile_revision": matrix_row["revision"], "ledger_status": entry["status"], "exit_code": entry["exit_code"],
        "validate_exit_code": entry["validate_exit_code"], "retry_of": entry["retry_of"],
        "stopped_by_supervisor": entry["stopped_by_supervisor"], "network": entry["network"],
        "elapsed_s": entry["elapsed_s"], "binary_sha256": matrix_row["binary_sha256"],
        "observed_peak_rss_bytes_supervisor_one_pid": entry["observed_peak_rss_bytes"],
        "environment_created": environment["created_wall_time"],
        "source_tree": {"git_revision": environment["build"]["git_revision"], "git_dirty": environment["build"]["git_dirty"]},
        "state": status["state"], "failure": status["failure"], "mock": metrics["mock"],
        "coverage": summary["coverage"], "data_loss": summary["data_loss"],
        "integrity": {k: summary["integrity"][k] for k in ("spool_sha256", "spool_frames", "pre_replay_verified",
                                                            "end_of_stream_verified")},
        "initial_validation": load(run / "validation.json")["status"],
        "derived_validations": [load(p)["status"] for p in derived],
        "sealed_sha256": {name: digests[name] for name in ("predictions.json", "metrics.json", "runtime_summary.json",
                                                           "events.jsonl", "config.json") if name in digests},
        "conditions_before": conditions(entry.get("conditions_before")),
        "accuracy": {k: v["value"] for k, v in metrics["accuracy"].items()},
    }


def recompute(rp, per_run_csv: Path, summary_csv: Path, records: list[dict]) -> dict:
    rows = list(csv.DictReader(per_run_csv.open(encoding="utf-8")))
    problems: list[str] = []
    by_id = {r["run_id"]: r for r in rows}
    for record in records:
        row = by_id.get(record["run_id"])
        if row is None:
            problems.append(f"{record['run_id']} missing from results-per-run.csv")
            continue
        for key, value in record["accuracy"].items():
            cell = row.get(key, "")
            if value is None and cell not in ("", "None"):
                problems.append(f"{record['run_id']} {key}: metrics null, CSV {cell!r}")
            elif value is not None and (cell == "" or float(cell) != value):
                problems.append(f"{record['run_id']} {key}: metrics {value!r}, CSV {cell!r}")
    numeric = []
    for row in rows:
        parsed: dict = {"row": row["row"], "eligible": row["eligible"] == "True"}
        for key in rp.SUMMARY_KEYS:
            parsed[key] = float(row[key]) if row.get(key) not in (None, "", "None") else None
        numeric.append(parsed)
    summary = rp.summarize(numeric)
    published = {r["row"]: r for r in csv.DictReader(summary_csv.open(encoding="utf-8"))}
    compared = 0
    for row_id, record in summary.items():
        for key in rp.SUMMARY_KEYS:
            expected = rp.fmt(record.get(key))
            if published[row_id].get(key) != expected:
                problems.append(f"summary {row_id} {key}: recomputed {expected!r}, published {published[row_id].get(key)!r}")
            compared += 1
        if int(published[row_id]["valid_n"]) != record["valid_n"]:
            problems.append(f"summary {row_id} valid_n differs")
    distinct = {(r["row"], r["repetition"]) for r in records}
    if len(distinct) != len(records):
        problems.append("duplicate (row, repetition) among measured runs")
    return {"status": "pass" if not problems else "fail", "problems": problems,
            "per_run_accuracy_checked": sum(len(r["accuracy"]) for r in records), "summary_cells_compared": compared,
            "distinct_row_repetitions": len(distinct),
            "method": "accuracy re-read from each sealed metrics.json; summaries re-derived with "
                      "scripts/report_phase1.py summarize()/fmt() from results-per-run.csv"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--session", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    session, out = args.session.resolve(), args.out.resolve()
    if out.exists():
        parser.error(f"{out} already exists; choose a new --out")
    campaign = session / "campaign"
    ledger = [json.loads(line) for line in (campaign / "ledger.jsonl").read_text().splitlines() if line.strip()]
    measured = [e for e in ledger if e.get("kind") == "measured"]
    matrix = load(campaign / "matrix.json")
    records = [run_record(campaign / "runs", e, matrix["rows"][e["row"]])
               for e in sorted(measured, key=lambda e: (e["row"], e["repetition"]))]
    rp = report_module()
    check = recompute(rp, session / COPIES["results-per-run.csv"], session / COPIES["results-summary.csv"], records)
    if check["status"] != "pass":
        for problem in check["problems"]:
            print(f"recomputation: {problem}", file=sys.stderr)
        return 1

    summary = load(campaign / "campaign-summary.json")
    snapshot_end = load(session / "snapshot-end.json")
    provenance = {
        "packet_version": 1, "session": session.name,
        "campaign": {k: summary[k] for k in ("started", "finished", "status", "rows", "blocked", "sandbox_denial_enforced",
                                             "package_resolved_sha256", "dataset_freeze_sha256", "inputs_sha256")}
                    | {"binaries": {k: {"sha256": v["sha256"], "version": v["version"], "frameworks": v["frameworks"]}
                                    for k, v in summary["binaries"].items()}},
        "matrix": matrix,
        "schema_bundle": snapshot_end["snapshot"]["schema_bundle"],
        "protected_inputs": snapshot_end["comparison"],
        "host": host_identity([load(campaign / "runs" / e["run_id"] / "environment.json") for e in measured]),
        "profiles": [profile_identity(p) for p in sorted((campaign / "profiles").glob("*.json"))],
        "dataset": dataset_identity(load(session / "datasets/dataset-freeze.json")),
        "runs": records,
        "checks": [{k: e.get(k) for k in ("kind", "row", "run_id", "status", "exit_code", "elapsed_s", "network")}
                   for e in ledger if e.get("kind") != "measured" and e.get("kind") != "setup"],
    }
    text = json.dumps(provenance, indent=2, ensure_ascii=False)
    if "/Users/" in text or "/private/" in text or "/var/folders" in text:
        print("provenance would contain an absolute local path; refusing", file=sys.stderr)
        return 1

    out.mkdir(parents=True)
    originals = {}
    for name, relative in COPIES.items():
        source = session / relative
        shutil.copyfile(source, out / name)
        if sha256(out / name) != sha256(source):
            raise RuntimeError(f"copy of {relative} differs from the original")
        originals[name] = {"original": relative, "sha256": sha256(source)}
    (out / "provenance.json").write_text(text + "\n", encoding="utf-8")
    (out / "recomputation.json").write_text(json.dumps(check | {"copies": originals}, indent=2) + "\n", encoding="utf-8")
    lines = [f"{sha256(p)}  {p.name}" for p in sorted(out.iterdir()) if p.is_file()]
    (out / "MANIFEST.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {len(lines) + 1} files to {out}; recomputation {check['status']} "
          f"({check['per_run_accuracy_checked']} accuracy values, {check['summary_cells_compared']} summary cells)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
