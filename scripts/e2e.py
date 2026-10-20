#!/usr/bin/env python3
"""End-to-end CLI sequence (plan M6, V16/V17): run -> validate -> compare -> export,
plus negative cases with their categorized exit codes.

Every step records the actual argv, exit code and expected exit code in
``<out>/commands.json``; the script exits nonzero if any step deviates. It
never assumes a success: each expectation is checked against the real process.

    .venv/bin/python scripts/e2e.py --voicebench .build/release/voicebench --out evidence/M6/e2e
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--voicebench", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    vb = str(Path(args.voicebench).resolve())
    out = Path(args.out).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    runs = out / "runs"
    steps: list[dict] = []

    def step(name: str, argv: list[str], expected: int, check=None) -> subprocess.CompletedProcess:
        started = time.monotonic()
        result = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=1800, check=False)
        detail = None
        ok = result.returncode == expected
        if ok and check is not None:
            detail = check()
            ok = detail is True
        steps.append({"name": name, "argv": argv, "exit_code": result.returncode, "expected_exit_code": expected,
                      "status": "pass" if ok else "fail", "duration_s": round(time.monotonic() - started, 3),
                      "check": None if detail in (None, True) else str(detail),
                      "stdout_tail": result.stdout[-1500:], "stderr_tail": result.stderr[-1500:]})
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: exit {result.returncode} (expected {expected})")
        return result

    def run(config: str, run_id: str, expected: int = 0, extra: list[str] | None = None):
        return step(f"run {run_id}", [vb, "run", "--config", f"configs/{config}", "--runs-dir", str(runs),
                                      "--run-id", run_id, *(extra or [])], expected)

    def status(run_id: str) -> str:
        return json.loads((runs / run_id / "status.json").read_text())["state"]

    # Successful runs.
    run("mock-step.yaml", "step-a")
    run("mock-step.yaml", "step-b")
    step("sealed run records the frozen schema bundle", [sys.executable, "-c", "print('checked in-process')"], 0,
         lambda: json.loads((runs / "step-a/config.json").read_text())["schema_bundle"]["frozen"] is True
         or "schema_bundle.frozen is not true")
    run("mock-step-hi.yaml", "hindi")
    run("mock-step-endpoint.yaml", "endpoint")
    run("mock-step.yaml", "step-override", extra=["--frame-ms", "40", "--seed", "7"])
    step("override frozen into config", [sys.executable, "-c", "print('checked in-process')"], 0,
         lambda: (json.loads((runs / "step-override/config.json").read_text())["settings"]["replay"]["frame_ms"] == 40
                  and json.loads((runs / "step-override/config.json").read_text())["replay_resolved"]["frame_samples"] == 640)
         or "frame_ms override not frozen")
    run("mock-accelerated.yaml", "accel-a")
    run("mock-accelerated.yaml", "accel-b")
    run("mock-slow-drop.yaml", "slow-drop")
    run("mock-slow-block.yaml", "slow-block")

    # Validation and rescoring.
    for run_id in ("step-a", "hindi", "endpoint", "slow-drop", "slow-block", "accel-a"):
        step(f"validate {run_id}", [vb, "validate", "--run", str(runs / run_id)], 0)
    step("validate endpoint --require-exact-endpoints", [vb, "validate", "--run", str(runs / "endpoint"),
                                                         "--require-exact-endpoints"], 9)
    step("rescore step-a", [vb, "validate", "--run", str(runs / "step-a"), "--rescore", "--analysis-id", "recheck-1"], 0,
         lambda: (runs / "step-a/derived/recheck-1/metrics.json").exists() or "rescore output missing")
    step("rescore keeps the initial metrics", [vb, "validate", "--run", str(runs / "step-a")], 0)
    step("rescore id reuse refused", [vb, "validate", "--run", str(runs / "step-a"), "--rescore", "--analysis-id",
                                      "recheck-1"], 2)

    # Comparison (V17).
    step("compare identical step runs (accuracy)", [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "step-b"),
                                                    "--profile", "accuracy", "--out", str(out / "cmp-accuracy")], 0,
         lambda: json.loads((out / "cmp-accuracy/comparison.json").read_text())["ranking"] is not None or "no ranking")
    step("compare en vs hi (accuracy) rejected", [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "hindi"),
                                                  "--profile", "accuracy", "--out", str(out / "cmp-en-hi")], 8)
    step("compare en vs hi with override", [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "hindi"),
                                            "--profile", "accuracy", "--allow-noncomparable",
                                            "--out", str(out / "cmp-en-hi-override")], 0,
         lambda: (lambda r: (not r["compatible"] and r["ranking"] is None and r["allow_noncomparable"]) or "override ranked")(
             json.loads((out / "cmp-en-hi-override/comparison.json").read_text())))
    step("compare step latency rejected", [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "step-b"),
                                           "--profile", "latency", "--out", str(out / "cmp-step-latency")], 8)
    step("compare accelerated latency", [vb, "compare", "--runs", str(runs / "accel-a"), str(runs / "accel-b"),
                                         "--profile", "latency", "--out", str(out / "cmp-accel-latency")], 0)
    step("compare lossy run rejected", [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "slow-drop"),
                                        "--profile", "accuracy", "--out", str(out / "cmp-lossy")], 8)
    step("compare changed seed+frame discloses, still accuracy-comparable",
         [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "step-override"), "--profile", "accuracy",
          "--out", str(out / "cmp-override")], 0,
         lambda: any(r["field"] == "seed" and r["effect"] == "disclosed"
                     for r in json.loads((out / "cmp-override/comparison.json").read_text())["reasons"]) or "seed not disclosed")

    # Export.
    step("export step-a", [vb, "export", "--run", str(runs / "step-a"), "--out", str(out / "export-step"), "--format", "all"], 0)
    step("export hindi csv", [vb, "export", "--run", str(runs / "hindi"), "--out", str(out / "export-hindi"),
                              "--format", "csv"], 0,
         lambda: "की" in (out / "export-hindi/predictions.csv").read_text(encoding="utf-8") or "Unicode lost in CSV")
    step("export into a non-empty directory refused", [vb, "export", "--run", str(runs / "step-a"), "--out",
                                                       str(out / "export-step")], 2)

    # Negative cases and exit categories (plan G3).
    step("invalid flag", [vb, "run", "--config", "configs/mock-step.yaml", "--runs-dir", str(runs), "--bogus"], 2)
    step("invalid frame size override", [vb, "run", "--config", "configs/mock-step.yaml", "--runs-dir", str(runs),
                                         "--run-id", "bad-frame", "--frame-ms", "30"], 2)
    step("speed outside accelerated mode", [vb, "run", "--config", "configs/mock-step.yaml", "--runs-dir", str(runs),
                                            "--run-id", "bad-speed", "--speed", "2"], 2)
    step("existing run id refused", [vb, "run", "--config", "configs/mock-step.yaml", "--runs-dir", str(runs),
                                     "--run-id", "step-a"], 2)
    pending = out / "pending.yaml"
    pending.write_text((ROOT / "configs/mock-step.yaml").read_text().replace(
        "../datasets/manifests/synthetic.json", str(ROOT / "datasets/manifests/hindi-pending.json")).replace(
        "../.venv/bin/python", str(ROOT / ".venv/bin/python")))
    step("pending dataset cannot run", [vb, "run", "--config", str(pending), "--runs-dir", str(runs), "--run-id",
                                        "pending"], 3, lambda: not (runs / "pending").exists() or "run dir created")
    step("strict endpoint policy refuses correction", [vb, "run", "--config", "configs/mock-step-endpoint-strict.yaml",
                                                       "--runs-dir", str(runs), "--run-id", "strict"], 4,
         lambda: status("strict") == "failed" or "status not failed")
    step("validate failed run", [vb, "validate", "--run", str(runs / "strict")], 9)
    step("compare with a failed run rejected", [vb, "compare", "--runs", str(runs / "step-a"), str(runs / "strict"),
                                                "--profile", "accuracy", "--out", str(out / "cmp-failed")], 8)
    corrupt = runs / "corrupt"
    shutil.copytree(runs / "step-b", corrupt)
    events = corrupt / "events.jsonl"
    events.write_bytes(events.read_bytes()[:-200])
    step("validate truncated trace", [vb, "validate", "--run", str(corrupt)], 9)
    step("validate dataset synthetic --require-ready", [vb, "validate", "--dataset",
                                                        "datasets/manifests/synthetic.json", "--require-ready"], 0)
    step("validate pending dataset", [vb, "validate", "--dataset", "datasets/manifests/hindi-pending.json"], 0)
    step("validate pending dataset --require-ready", [vb, "validate", "--dataset",
                                                      "datasets/manifests/hindi-pending.json", "--require-ready"], 9)
    step("validate selectors are exclusive", [vb, "validate", "--run", str(runs / "step-a"), "--dataset",
                                              "datasets/manifests/synthetic.json"], 2)
    step("compare needs two runs", [vb, "compare", "--runs", str(runs / "step-a"), "--profile", "accuracy",
                                    "--out", str(out / "cmp-one")], 2)

    report = {"status": "pass" if all(s["status"] == "pass" for s in steps) else "fail", "voicebench": vb,
              "steps": steps}
    (out / "commands.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    failed = [s["name"] for s in steps if s["status"] != "pass"]
    print(f"e2e: {report['status']} ({len(steps) - len(failed)}/{len(steps)})" + (f"; failed: {failed}" if failed else ""))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
