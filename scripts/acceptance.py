#!/usr/bin/env python3
"""Gate A acceptance runner (plan G1/M7): maps every mandatory V-ID to concrete
commands and evidence, and writes ``<out>/Vnn/result.json`` plus ``<out>/acceptance.json``.

Rules: a V-ID passes only when every one of its commands exits as expected and every
evidence check holds. Long campaigns (performance, offline, determinism) are not
re-run here; they are *external evidence inputs*: when an input is missing, the
V-ID is ``not_run`` and the suite is incomplete, never passed.

    .venv/bin/python scripts/acceptance.py --voicebench .build/release/voicebench --gate-a --out evidence/M7/acceptance
    .venv/bin/python scripts/acceptance.py --voicebench .build/release/voicebench --only V11 --out evidence/M7/acceptance
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
PY = str(ROOT / ".venv/bin/python")
sys.path.insert(0, str(ROOT / "analysis/src"))

#: V-ID -> (requirement IDs, Swift test filters, pytest files, extra check name or None)
TABLE: dict[str, tuple[list[str], list[str], list[str], str | None]] = {
    "V01": (["FR-01"], ["WAVDecoderTests"], [], None),
    "V02": (["FR-02"], ["ConversionTests", "ResamplingEdgeTests"], ["test_schemas.py"], None),
    "V03": (["FR-02", "FR-04"], ["SampleClockTests", "ClockTests"], [], None),
    "V04": (["FR-03"], ["ChunkContinuityTests", "ReplayModeTests", "AudioIntegrityTests"], [], None),
    "V05": (["FR-03", "FR-14"], ["StepDeterminismTests"], ["test_trace.py"], "determinism"),
    "V06": (["FR-03"], ["ReplayModeTests"], ["test_cli.py"], None),
    "V07": (["FR-03", "FR-04"], ["ReplayModeTests"], [], "realtime"),
    "V08": (["FR-05", "FR-08"], [], ["test_asr_goldens.py", "test_score_integration.py"], None),
    "V09": (["FR-05", "FR-08"], [], ["test_diarization_goldens.py", "test_score_integration.py"], None),
    "V10": (["FR-04", "FR-09"], ["StageTimingTests", "ReplayClockDomainTests"], ["test_timing_metrics.py"], None),
    "V11": (["FR-06", "FR-09"], ["BoundedQueueTests", "QueueHardeningTests", "RecorderTests"], [], "loss_audit"),
    "V12": (["FR-09"], ["ProcessSamplerTests", "TelemetryStatusTests", "TelemetryErrorTests"],
            ["test_resource_metrics.py"], "telemetry"),
    "V13": (["FR-07", "FR-11"], ["BenchmarkSupportTests", "EventValidityTests"], ["test_schemas.py"], "schema_check"),
    "V14": (["FR-07"], ["ProvenanceTests"], [], None),
    "V15": (["FR-06", "FR-11"], ["RecorderTests", "PartialRunTests", "RunLifecycleTests"],
            ["test_artifact_validation.py"], None),
    "V16": (["FR-10", "FR-11"], ["CLIEndToEndTests", "ExitCodeTests", "OverrideTests"], ["test_export.py"], "e2e"),
    "V17": (["FR-12"], [], ["test_compatibility.py"], None),
    "V18": (["FR-08", "FR-14"], [], ["test_trace.py", "test_score_integration.py"], "determinism"),
    "V19": (["FR-14"], [], ["test_doctor.py"], "offline"),
    "V20": (["FR-05"], ["AdapterContractTests", "RunnerExtensionTests"], [], None),
}


def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="milliseconds")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Result:
    def __init__(self, vid: str, out: Path) -> None:
        self.vid, self.dir = vid, out / vid
        self.dir.mkdir(parents=True)  # refuses an existing case directory; main() checks all of them first
        self.commands: list[dict[str, Any]] = []
        self.checks: list[dict[str, Any]] = []
        self.evidence: dict[str, str] = {}
        self.started = now()

    def command(self, name: str, argv: list[str], expected: int = 0, env: dict | None = None) -> int:
        log = self.dir / f"{len(self.commands) + 1:02d}-{name}.log"
        t0 = time.monotonic()
        with log.open("w", encoding="utf-8") as handle:
            handle.write(f"$ {' '.join(argv)}\n\n")
            handle.flush()
            code = subprocess.run(argv, cwd=ROOT, stdout=handle, stderr=subprocess.STDOUT, timeout=3600,
                                  env=env, check=False).returncode
        self.commands.append({"name": name, "argv": argv, "cwd": str(ROOT), "exit_code": code, "expected_exit_code": expected,
                              "duration_s": round(time.monotonic() - t0, 3), "log": str(log.relative_to(ROOT)),
                              "status": "pass" if code == expected else "fail"})
        return code

    def check(self, name: str, ok: bool, observed: Any) -> None:
        self.checks.append({"name": name, "status": "pass" if ok else "fail", "observed": observed})

    def missing(self, name: str, path: Path) -> None:
        self.checks.append({"name": name, "status": "not_run", "observed": f"external evidence input missing: {path}"})

    def require_tests(self, report: Path, kind: str) -> None:
        """An empty test selection must never count as a pass."""
        import xml.etree.ElementTree as ET

        if not report.exists():
            return self.check(f"{kind} report present", False, str(report))
        root = ET.parse(report).getroot()
        suite = root if root.tag == "testsuite" else next(root.iter("testsuite"), None)
        counts = {k: int((suite.get(k) if suite is not None else None) or 0) for k in ("tests", "failures", "errors", "skipped")}
        self.check(f"{kind} executed tests with no failures or skips",
                   counts["tests"] > 0 and counts["failures"] == counts["errors"] == counts["skipped"] == 0, counts)

    def attach(self, path: Path) -> None:
        if path.is_file():
            self.evidence[str(path.relative_to(ROOT)) if ROOT in path.parents else str(path)] = sha256(path)

    def finish(self, requirements: list[str]) -> dict[str, Any]:
        statuses = [c["status"] for c in self.commands] + [c["status"] for c in self.checks]
        status = "fail" if "fail" in statuses else ("not_run" if "not_run" in statuses else "pass")
        result = {"test_id": self.vid, "requirement_ids": requirements, "started": self.started, "ended": now(),
                  "status": status, "commands": self.commands, "checks": self.checks, "evidence": self.evidence,
                  "tool_versions": {"python": sys.version.split()[0]}}
        (self.dir / "result.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return result


def env() -> dict[str, str]:
    return dict(os.environ, PYTHONPATH=str(ROOT / "analysis/src"), MPLBACKEND="Agg", PYTHONDONTWRITEBYTECODE="1",
                PYTHONHASHSEED="0")


# ------------------------------------------------------------------ extra checks --

def check_determinism(r: Result, inputs: dict[str, Path], vb: str) -> None:
    path = inputs["determinism"] / "equality.json"
    if not path.exists():
        return r.missing("three-process step determinism", path)
    data = json.loads(path.read_text())
    r.attach(path)
    complete = data["repeats"] == 3 and all(run["exit_code"] == 0 for run in data["runs"])
    if r.vid == "V05":
        r.check("normalized event traces equal across 3 processes", complete and data["status"] == "pass"
                and len({run.get("normalized_events_sha256") for run in data["runs"]}) == 1,
                {"status": data["status"], "digests": [run.get("normalized_events_sha256") for run in data["runs"]]})
    else:
        r.check("predictions and accuracy-metric projections equal across 3 processes", complete and
                len({run.get("predictions_projection_sha256") for run in data["runs"]}) == 1 and
                len({run.get("metrics_projection_sha256") for run in data["runs"]}) == 1,
                {"predictions": [run.get("predictions_projection_sha256") for run in data["runs"]],
                 "metrics": [run.get("metrics_projection_sha256") for run in data["runs"]]})


def check_realtime(r: Result, inputs: dict[str, Path], vb: str) -> None:
    path = inputs["performance"] / "characterization.json"
    if not path.exists():
        return r.missing("P01 real-time campaign runs", path)
    data = json.loads(path.read_text())
    r.attach(path)
    runs = data["P01"]["runs"]
    ok = (data["P01"]["completed_runs"] == data["P01"]["requested_runs"] == 3
          and all(run["dropped_samples"] == 0 and run["full_signed"]["status"] == "ok" and run["wake_error"]["status"] == "ok"
                  for run in runs))
    r.check("real-time runs recorded planned/offer/admission errors with no silent loss (the 20 ms target is P01, "
            "investigatory, not asserted here)", ok,
            [{"run": run["run_id"], "n": run["full_signed"]["n"], "dropped": run["dropped_samples"]} for run in runs])


def check_loss_audit(r: Result, inputs: dict[str, Path], vb: str) -> None:
    runs = r.dir / "runs"
    for config, run_id in (("mock-slow-drop.yaml", "slow-drop"), ("mock-slow-block.yaml", "slow-block")):
        r.command(f"run-{run_id}", [vb, "run", "--config", f"configs/{config}", "--runs-dir", str(runs), "--run-id", run_id])
        r.command(f"validate-{run_id}", [vb, "validate", "--run", str(runs / run_id)])
    from phase0_analysis.trace import read_trace

    audit = {}
    for run_id in ("slow-drop", "slow-block"):
        d = runs / run_id
        if not (d / "events.jsonl").exists():
            r.check(f"{run_id} sealed", False, "run did not complete")
            continue
        summary = json.loads((d / "runtime_summary.json").read_text())
        events = read_trace(d / "events.jsonl").events
        overflow = [e["payload"] for e in events if e["type"] == "audio.queue_overflow"]
        delivered = {e["payload"]["chunk_index"] for e in events if e["type"] == "audio.chunk_delivered"}
        dropped_ids = {p["chunk_index"] for p in overflow}
        ranges = summary["coverage"]["dropped_ranges"]
        audit[run_id] = {"dropped_samples": summary["coverage"]["dropped_samples"], "dropped_chunks": len(overflow),
                         "ranges": len(ranges), "max_queue_depth": summary["queues"]["audio_max_depth"],
                         "backpressure_events": sum(1 for e in events if e["type"] == "audio.queue_backpressure")}
        exact = (sum(p["lost_samples"] for p in overflow) == summary["coverage"]["dropped_samples"]
                 == sum(x["end_sample"] - x["start_sample"] for x in ranges)
                 and (overflow[-1]["cumulative_lost_samples"] if overflow else 0) == summary["coverage"]["dropped_samples"]
                 and not delivered & dropped_ids and summary["queues"]["audio_max_depth"] <= 4)
        if run_id == "slow-drop":
            r.check("drop_newest: exact dropped ranges, no dropped chunk delivered, capacity respected",
                    exact and summary["data_loss"] and overflow != [], audit[run_id])
        else:
            r.check("block: lossless with recorded backpressure, capacity respected",
                    exact and not summary["data_loss"] and audit[run_id]["backpressure_events"] > 0, audit[run_id])
    (r.dir / "loss-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
    r.attach(r.dir / "loss-audit.json")


def check_telemetry(r: Result, inputs: dict[str, Path], vb: str) -> None:
    path = inputs["performance"] / "characterization.json"
    if not path.exists():
        return r.missing("target-machine CPU/RSS telemetry (P04)", path)
    data = json.loads(path.read_text())
    r.attach(path)
    r.check("CPU % and current RSS sampled on this machine in every telemetry-on campaign run",
            data["P04"]["cpu_and_rss_present_in_all"],
            [{"run": p["run_id"], "cpu": p["cpu_percent"]["status"], "rss_peak": p["rss_peak_sampled_bytes"]}
             for p in data["P04"]["runs"]])


def check_schema(r: Result, inputs: dict[str, Path], vb: str) -> None:
    out = r.dir / "schema-check.json"
    r.command("schema-check", [PY, "-m", "phase0_analysis", "schema-check", "--schemas", "schemas/v1", "--fixtures",
                               "testdata/schemas", "--out", str(out)], env=env())
    r.attach(out)


def check_e2e(r: Result, inputs: dict[str, Path], vb: str) -> None:
    r.command("e2e", [PY, "scripts/e2e.py", "--voicebench", vb, "--out", str(r.dir / "e2e")], env=env())
    r.attach(r.dir / "e2e/commands.json")


def check_offline(r: Result, inputs: dict[str, Path], vb: str) -> None:
    path = inputs["offline"] / "offline.json"
    if not path.exists():
        return r.missing("enforced-offline end-to-end smoke", path)
    data = json.loads(path.read_text())
    control = json.loads((inputs["offline"] / "control.json").read_text())
    r.attach(path)
    r.attach(inputs["offline"] / "control.json")
    r.check("network denial enforced (positive and negative control)", control["denial_enforced"], control)
    r.check("full e2e under enforced denial with empty model caches", data["status"] == "pass", data)


EXTRA: dict[str, Callable[[Result, dict[str, Path], str], None]] = {
    "determinism": check_determinism, "realtime": check_realtime, "loss_audit": check_loss_audit,
    "telemetry": check_telemetry, "schema_check": check_schema, "e2e": check_e2e, "offline": check_offline,
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicebench", required=True)
    parser.add_argument("--out", required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--gate-a", action="store_true")
    group.add_argument("--only", choices=sorted(TABLE))
    parser.add_argument("--evidence-root", default="evidence/M7")
    args = parser.parse_args()
    vb = str(Path(args.voicebench).resolve())
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    root = Path(args.evidence_root).resolve()
    inputs = {"determinism": root / "determinism", "performance": root / "performance", "offline": root / "offline"}
    ids = sorted(TABLE) if args.gate_a else [args.only]
    existing = [vid for vid in ids if (out / vid).exists()] + (["acceptance.json"] if args.gate_a and (out / "acceptance.json").exists() else [])
    if existing:
        parser.error(f"{out} already holds {', '.join(existing)}; choose a new --out (existing evidence is never deleted)")
    results = []
    for vid in ids:
        requirements, filters, pytests, extra = TABLE[vid]
        r = Result(vid, out)
        if filters:
            xunit = r.dir / "xunit.xml"
            r.command("swift-test", ["scripts/swift_test.sh", "--filter", "|".join(filters), "--xunit-output", str(xunit)])
            r.require_tests(xunit, "swift")
            r.attach(xunit)
        if pytests:
            junit = r.dir / "pytest.xml"
            r.command("pytest", [PY, "-m", "pytest", *[f"analysis/tests/{p}" for p in pytests], "-q", "--junitxml",
                                 str(junit)], env=env())
            r.require_tests(junit, "pytest")
            r.attach(junit)
        if extra:
            EXTRA[extra](r, inputs, vb)
        results.append(r.finish(requirements))
        print(f"[{results[-1]['status'].upper()}] {vid}", flush=True)
    if args.gate_a:
        summary = {"created": now(), "voicebench": vb, "results": {r["test_id"]: r["status"] for r in results},
                   "status": "pass" if all(r["status"] == "pass" for r in results)
                   else ("fail" if any(r["status"] == "fail" for r in results) else "incomplete")}
        (out / "acceptance.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"acceptance: {summary['status']}")
        return 0 if summary["status"] == "pass" else 1
    return 0 if results[0]["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
