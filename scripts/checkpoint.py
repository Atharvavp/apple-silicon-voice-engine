#!/usr/bin/env python3
"""Milestone checkpoint runner (plan F0).

Runs every command of a milestone group sequentially (argument arrays, no
shell), records executable/args/cwd/start/end/exit, captures full logs, and
writes ``<out>/checkpoint.json``. Exits nonzero if any required command fails.
All commands run even after a failure so the evidence is complete; the
checkpoint status is still ``fail``.

Usage: .venv/bin/python scripts/checkpoint.py M1 --out evidence/M1
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PY = str(ROOT / ".venv/bin/python")


def groups(out: Path) -> dict[str, list[tuple[str, list[str]]]]:
    """Milestone -> [(name, argv)]. Later milestones append regression commands."""
    m1 = [
        ("swift-build", ["swift", "build"]),
        ("voicebench-version", [str(ROOT / ".build/debug/voicebench"), "--version"]),
        ("voicebench-help", [str(ROOT / ".build/debug/voicebench"), "--help"]),
        ("swift-test-benchmark-support", ["scripts/swift_test.sh", "--filter", "BenchmarkSupportTests",
                                          "--xunit-output", str(out / "xunit-benchmark-support.xml")]),
        ("pip-check", [PY, "-m", "pip", "check"]),
        ("pytest-schemas-doctor", [PY, "-m", "pytest", "analysis/tests/test_schemas.py",
                                   "analysis/tests/test_doctor.py", "-q", "--junitxml", str(out / "pytest-m1.xml")]),
        ("doctor", [PY, "-m", "phase0_analysis", "doctor", "--schemas", "schemas/v1", "--out",
                    str(out / "doctor.json")]),
        ("schema-check", [PY, "-m", "phase0_analysis", "schema-check", "--schemas", "schemas/v1", "--fixtures",
                          "testdata/schemas", "--out", str(out / "schema-check.json")]),
    ]
    m2 = [
        ("fixtures-reproducible", [PY, "scripts/generate_fixtures.py", "--small", "--out", "datasets/fixtures",
                                   "--verify"]),
        ("swift-build", ["swift", "build"]),
        ("swift-test-audio-core", ["scripts/swift_test.sh", "--filter", "AudioCoreTests",
                                   "--xunit-output", str(out / "xunit-audio-core.xml")]),
        ("swift-test-replay", ["scripts/swift_test.sh", "--filter", "ReplayTests",
                               "--xunit-output", str(out / "xunit-replay.xml")]),
        ("swift-test-all-regression", ["scripts/swift_test.sh", "--xunit-output", str(out / "xunit-all.xml")]),
        ("pytest-all-regression", [PY, "-m", "pytest", "analysis/tests", "-q", "--junitxml",
                                   str(out / "pytest-all.xml")]),
        ("schema-check", [PY, "-m", "phase0_analysis", "schema-check", "--schemas", "schemas/v1", "--fixtures",
                          "testdata/schemas", "--out", str(out / "schema-check.json")]),
    ]
    hardening = [
        ("fixtures-reproducible", [PY, "scripts/generate_fixtures.py", "--small", "--out", "datasets/fixtures",
                                   "--verify"]),
        ("swift-build", ["swift", "build"]),
        *[(f"h1-queue-stress-process-{n}", ["scripts/swift_test.sh", "--filter", "QueueHardeningTests",
                                            "--xunit-output", str(out / f"xunit-h1-{n}.xml")]) for n in (1, 2, 3)],
        ("h2-audio-integrity", ["scripts/swift_test.sh", "--filter", "AudioIntegrityTests",
                                "--xunit-output", str(out / "xunit-h2.xml")]),
        ("h3-resampling-edges", ["scripts/swift_test.sh", "--filter", "ResamplingEdgeTests",
                                 "--xunit-output", str(out / "xunit-h3.xml")]),
        ("swift-test-all-regression", ["scripts/swift_test.sh", "--xunit-output", str(out / "xunit-all.xml")]),
        ("pytest-all-regression", [PY, "-m", "pytest", "analysis/tests", "-q", "--junitxml",
                                   str(out / "pytest-all.xml")]),
        ("schema-check", [PY, "-m", "phase0_analysis", "schema-check", "--schemas", "schemas/v1", "--fixtures",
                          "testdata/schemas", "--out", str(out / "schema-check.json")]),
        ("doctor", [PY, "-m", "phase0_analysis", "doctor", "--schemas", "schemas/v1", "--out",
                    str(out / "doctor.json")]),
        # Last, because it rebuilds the test bundle with Thread Sanitizer instrumentation.
        ("tsan-concurrency-suites", ["scripts/swift_test.sh", "--sanitize=thread", "--filter",
                                     "QueueHardeningTests|BoundedQueueTests|AudioIntegrityTests|ReplayModeTests",
                                     "--xunit-output", str(out / "xunit-tsan.xml")]),
    ]
    common_tail = [
        ("swift-test-all-regression", ["scripts/swift_test.sh", "--xunit-output", str(out / "xunit-all.xml")]),
        ("pytest-all-regression", [PY, "-m", "pytest", "analysis/tests", "-q", "--junitxml",
                                   str(out / "pytest-all.xml")]),
        ("schema-check", [PY, "-m", "phase0_analysis", "schema-check", "--schemas", "schemas/v1", "--fixtures",
                          "testdata/schemas", "--out", str(out / "schema-check.json")]),
        ("doctor", [PY, "-m", "phase0_analysis", "doctor", "--schemas", "schemas/v1", "--out",
                    str(out / "doctor.json")]),
    ]
    m3 = [
        ("fixtures-reproducible", [PY, "scripts/generate_fixtures.py", "--small", "--out", "datasets/fixtures",
                                   "--verify"]),
        ("swift-build", ["swift", "build"]),
        ("swift-test-adapter-contracts", ["scripts/swift_test.sh", "--filter", "AdapterContractTests",
                                          "--xunit-output", str(out / "xunit-adapter-contracts.xml")]),
        ("swift-test-schema-roundtrip", ["scripts/swift_test.sh", "--filter", "SchemaRoundTripTests",
                                         "--xunit-output", str(out / "xunit-schema-roundtrip.xml")]),
        *common_tail,
    ]
    m4 = [
        ("fixtures-reproducible", [PY, "scripts/generate_fixtures.py", "--small", "--out", "datasets/fixtures",
                                   "--verify"]),
        ("swift-build", ["swift", "build"]),
        ("swift-test-experiment", ["scripts/swift_test.sh", "--filter", "ExperimentTests",
                                   "--xunit-output", str(out / "xunit-experiment.xml")]),
        ("pytest-trace-artifact-validation", [PY, "-m", "pytest", "analysis/tests/test_trace.py",
                                              "analysis/tests/test_artifact_validation.py", "-q", "--junitxml",
                                              str(out / "pytest-m4.xml")]),
        *common_tail,
        # Last, because it rebuilds the test bundle with Thread Sanitizer instrumentation.
        ("tsan-recorder-and-runner", ["scripts/swift_test.sh", "--sanitize=thread", "--filter",
                                      "RecorderTests|RunLifecycleTests|PartialRunTests",
                                      "--xunit-output", str(out / "xunit-tsan.xml")]),
    ]
    release = str(ROOT / ".build/release/voicebench")
    m5 = [
        ("swift-build", ["swift", "build"]),
        ("swift-test-telemetry", ["scripts/swift_test.sh", "--filter", "TelemetryTests",
                                  "--xunit-output", str(out / "xunit-telemetry.xml")]),
        ("pytest-scoring-goldens", [PY, "-m", "pytest", "analysis/tests/test_asr_goldens.py",
                                    "analysis/tests/test_diarization_goldens.py", "analysis/tests/test_timing_metrics.py",
                                    "analysis/tests/test_resource_metrics.py", "analysis/tests/test_score_integration.py",
                                    "-q", "--junitxml", str(out / "pytest-m5.xml")]),
        ("swift-build-release", ["swift", "build", "-c", "release"]),
        ("voicebench-run-step", [release, "run", "--config", "configs/mock-step.yaml", "--runs-dir",
                                 str(out / "runs"), "--run-id", "m5-step"]),
        ("voicebench-run-hindi", [release, "run", "--config", "configs/mock-step-hi.yaml", "--runs-dir",
                                  str(out / "runs"), "--run-id", "m5-hi"]),
        ("validate-sealed-step", [PY, "-m", "phase0_analysis", "validate", "--run", str(out / "runs/m5-step"),
                                  "--out", str(out / "m5-step-validation.json")]),
        ("validate-sealed-hindi", [PY, "-m", "phase0_analysis", "validate", "--run", str(out / "runs/m5-hi"),
                                   "--out", str(out / "m5-hi-validation.json")]),
        *common_tail,
    ]
    m6 = [
        ("swift-build", ["swift", "build"]),
        ("swift-test-cli", ["scripts/swift_test.sh", "--filter", "BenchmarkCLITests",
                            "--xunit-output", str(out / "xunit-cli.xml")]),
        ("pytest-compare-export-cli", [PY, "-m", "pytest", "analysis/tests/test_compatibility.py",
                                       "analysis/tests/test_export.py", "analysis/tests/test_cli.py", "-q",
                                       "--junitxml", str(out / "pytest-m6.xml")]),
        ("swift-build-release", ["swift", "build", "-c", "release"]),
        ("e2e-release", [PY, "scripts/e2e.py", "--voicebench", release, "--out", str(out / "e2e")]),
        *common_tail,
    ]
    m7 = [
        ("fixtures-reproducible", [PY, "scripts/generate_fixtures.py", "--small", "--out", "datasets/fixtures",
                                   "--verify"]),
        ("swift-build", ["swift", "build"]),
        ("swift-build-release-pinned", ["swift", "build", "-c", "release", "--disable-automatic-resolution",
                                        "--skip-update"]),
        *common_tail,
        ("gate-a-suite", [release, "validate", "--suite", "gate-a", "--evidence-dir", str(ROOT / "evidence/M7")]),
        # Last, because it rebuilds the test bundle with Thread Sanitizer instrumentation.
        ("tsan-concurrency-suites", ["scripts/swift_test.sh", "--sanitize=thread", "--filter",
                                     "QueueHardeningTests|BoundedQueueTests|AudioIntegrityTests|ReplayModeTests|"
                                     "RecorderTests|RunLifecycleTests|PartialRunTests|LifecycleTests|StageTimingTests",
                                     "--xunit-output", str(out / "xunit-tsan.xml")]),
    ]
    return {"M1": m1, "M2": m2, "M2-hardening": hardening, "M3": m3, "M4": m4, "M5": m5, "M6": m6, "M7": m7}


def sha256(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def capture(argv: list[str]) -> str | None:
    try:
        return subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=60, check=False).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None


def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="milliseconds")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("milestone", choices=["M1", "M2", "M2-hardening", "M3", "M4", "M5", "M6", "M7"])
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = (ROOT / args.out).resolve()
    if out.exists() and any(out.iterdir()):
        parser.error(f"{out} is not empty; choose a new --out (existing evidence is never overwritten)")
    logs = out / "logs"
    logs.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ, PYTHONPATH=str(ROOT / "analysis/src"), MPLBACKEND="Agg", PYTHONDONTWRITEBYTECODE="1",
               PYTHONHASHSEED="0", VOICEBENCH_EVIDENCE_DIR=str(out / "swift-evidence"))
    results = []
    for index, (name, argv) in enumerate(groups(out)[args.milestone], start=1):
        log_path = logs / f"{index:02d}-{name}.log"
        started, t0 = now(), time.monotonic()
        with log_path.open("w", encoding="utf-8") as log:
            log.write(f"$ {' '.join(argv)}\n\n")
            log.flush()
            try:
                code = subprocess.run(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
                                      timeout=3600, check=False).returncode
            except (OSError, subprocess.TimeoutExpired) as exc:
                log.write(f"\n[checkpoint] could not run: {exc}\n")
                code = -1
        results.append({"name": name, "argv": argv, "cwd": str(ROOT), "started": started, "ended": now(),
                        "duration_s": round(time.monotonic() - t0, 3), "exit_code": code,
                        "status": "pass" if code == 0 else "fail", "log": str(log_path.relative_to(ROOT))})
        print(f"[{'PASS' if code == 0 else 'FAIL'}] {name} ({results[-1]['duration_s']} s) -> {log_path.relative_to(ROOT)}")

    report = {
        "milestone": args.milestone,
        "status": "pass" if all(r["status"] == "pass" for r in results) else "fail",
        "created": now(),
        "environment": {
            "swift_version": capture(["swift", "--version"]),
            "sdk_version": capture(["xcrun", "--show-sdk-version"]),
            "developer_dir": capture(["xcode-select", "-p"]),
            "os": f"{platform.mac_ver()[0]} ({capture(['sw_vers', '-buildVersion'])})",
            "machine": platform.machine(),
            "hardware_model": capture(["sysctl", "-n", "hw.model"]),
            "cpu_brand": capture(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "memory_bytes": capture(["sysctl", "-n", "hw.memsize"]),
            "python": capture([PY, "--version"]),
            "git_revision": capture(["git", "rev-parse", "HEAD"]),
            "git_dirty": bool(capture(["git", "status", "--porcelain"])),
        },
        "digests": {
            "Package.resolved": sha256(ROOT / "Package.resolved"),
            "requirements-macos-arm64-py312.lock": sha256(ROOT / "analysis/requirements-macos-arm64-py312.lock"),
            "requirements-dev-macos-arm64-py312.lock": sha256(ROOT / "analysis/requirements-dev-macos-arm64-py312.lock"),
        },
        "commands": results,
    }
    (out / "checkpoint.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"checkpoint {args.milestone}: {report['status']} -> {(out / 'checkpoint.json').relative_to(ROOT)}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
