#!/usr/bin/env python3
"""Assertions for the beginner smoke run (used by scripts/smoke.sh); reads, never writes.

    .venv/bin/python scripts/smoke_check.py --run <run-dir> --export <export-dir> [--samples 192000]

A smoke run passes only if all of these hold, not merely the exit code:
  * status.json: state completed, no failure; every listed artifact exists with its recorded SHA-256;
  * mock adapters: metrics.json and predictions.json both say mock, and both adapter IDs are mock-*;
  * sample accounting: produced = admitted = consumed = the expected fixture samples, zero dropped,
    no data loss, spool verified before replay and at end of stream;
  * validation.json (initial, sealed with the run) and the newest derived validation both pass;
  * the export directory holds the documented CSV and PNG files.
Timing, CPU and memory values are machine-dependent and deliberately not checked.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REQUIRED_FILES = ["config.json", "environment.json", "events.jsonl", "metrics.json", "predictions.json",
                  "runtime_summary.json", "status.json", "telemetry.jsonl", "validation.json"]
EXPORT_FILES = ["metrics.csv", "predictions.csv", "timing.csv", "resources.csv", "loss-ranges.csv"]


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(run: Path, export: Path | None, samples: int) -> list[str]:
    problems: list[str] = []
    missing = [name for name in REQUIRED_FILES if not (run / name).is_file()]
    if missing:
        return [f"missing run artifacts: {', '.join(missing)}"]

    status = _load(run / "status.json")
    if status.get("state") != "completed" or status.get("failure") is not None:
        problems.append(f"run state {status.get('state')!r}, failure {status.get('failure')!r}")
    for artifact in status.get("artifacts", []):
        path = run / artifact["path"]
        if not path.is_file():
            problems.append(f"sealed artifact missing: {artifact['path']}")
        elif _sha256(path) != artifact["sha256"]:
            problems.append(f"sealed artifact digest mismatch: {artifact['path']}")

    metrics, predictions = _load(run / "metrics.json"), _load(run / "predictions.json")
    if metrics.get("mock") is not True or predictions.get("mock") is not True:
        problems.append("adapters are not labelled mock; the smoke path must not run real models")
    ids = {role: entry.get("id", "") for role, entry in (predictions.get("adapters") or {}).items()}
    if set(ids) != {"asr", "diarization"} or not all(i.startswith("mock-") for i in ids.values()):
        problems.append(f"unexpected adapters: {ids}")

    summary = _load(run / "runtime_summary.json")
    coverage = summary.get("coverage", {})
    for key in ("produced_samples", "admitted_samples", "consumed_samples"):
        if coverage.get(key) != samples:
            problems.append(f"{key} = {coverage.get(key)}, expected {samples}")
    if coverage.get("dropped_samples") != 0 or coverage.get("dropped_ranges"):
        problems.append(f"dropped samples: {coverage.get('dropped_samples')} {coverage.get('dropped_ranges')}")
    if summary.get("data_loss") is not False:
        problems.append(f"data_loss = {summary.get('data_loss')!r}")
    integrity = summary.get("integrity", {})
    if not (integrity.get("pre_replay_verified") and integrity.get("end_of_stream_verified")):
        problems.append(f"spool integrity not verified: {integrity}")

    if _load(run / "validation.json").get("status") != "pass":
        problems.append("initial validation.json is not pass")
    derived = sorted((run / "derived").glob("validation-*/validation.json"), key=lambda p: p.stat().st_mtime)
    if not derived:
        problems.append("no derived validation (run `voicebench validate --run` first)")
    elif _load(derived[-1]).get("status") != "pass":
        problems.append(f"derived validation {derived[-1].parent.name} is not pass")

    if export is not None:
        absent = [name for name in EXPORT_FILES if not (export / name).is_file()]
        if absent:
            problems.append(f"missing export files: {', '.join(absent)}")
        if not list(export.glob("*.png")):
            problems.append("export contains no PNG plots")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", required=True, type=Path)
    parser.add_argument("--export", type=Path)
    parser.add_argument("--samples", type=int, default=192000, help="expected fixture samples at 16 kHz")
    args = parser.parse_args()
    problems = check(args.run, args.export, args.samples)
    for problem in problems:
        print(f"smoke check: FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"smoke check: pass ({args.samples} samples consumed, 0 dropped, mock adapters, validation pass)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
