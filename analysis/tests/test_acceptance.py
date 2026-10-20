"""Suite evaluation and readiness decision rules (plan G1/I1): missing or failing
evidence never passes, and a P01 miss is never self-approved."""

from __future__ import annotations

import json
from pathlib import Path

from phase0_analysis.acceptance import V_IDS, evaluate
from phase0_analysis.readiness import decide


def write_results(root: Path, statuses: dict[str, str]) -> None:
    for vid, status in statuses.items():
        d = root / "acceptance" / vid
        d.mkdir(parents=True)
        (d / "result.json").write_text(json.dumps({"status": status, "requirement_ids": ["FR-01"],
                                                   "commands": [], "checks": []}))


def performance(met: bool, controlled: bool) -> dict:
    return {"controlled_idle_host": controlled, "P01": {"target_met_all_runs": met}}


def test_missing_results_make_the_suite_incomplete(tmp_path: Path) -> None:
    write_results(tmp_path, {vid: "pass" for vid in V_IDS[:-1]})
    report = evaluate(tmp_path)
    assert report["status"] == "incomplete"
    assert report["checks"][-1] == {"check_id": "V20", "status": "not_run", "message": "no result recorded",
                                    "evidence": None}


def test_one_failure_fails_the_suite(tmp_path: Path) -> None:
    write_results(tmp_path, {vid: ("fail" if vid == "V07" else "pass") for vid in V_IDS})
    assert evaluate(tmp_path)["status"] == "fail"


def test_not_run_results_never_pass(tmp_path: Path) -> None:
    write_results(tmp_path, {vid: ("not_run" if vid == "V19" else "pass") for vid in V_IDS})
    report = evaluate(tmp_path)
    assert report["status"] == "incomplete"
    assert decide(report, performance(True, True), None)[0] == "FAIL"


def test_decision_rules(tmp_path: Path) -> None:
    write_results(tmp_path, {vid: "pass" for vid in V_IDS})
    suite = evaluate(tmp_path)
    assert suite["status"] == "pass"
    assert decide(suite, None, None)[0] == "FAIL", "missing performance evidence"
    assert decide(suite, performance(False, True), None) == (
        "FAIL", "correctness passed; release pending owner approval of the P01 warning")
    assert decide(suite, performance(False, True), {"p01_warning_approved": True})[0] == "PASS_WITH_APPROVED_WARNINGS"
    decision, reason = decide(suite, performance(True, False), None)
    assert decision == "PASS" and "uncontrolled host" in reason and "not an owner-approved warning" in reason
    assert decide(suite, performance(True, True), None)[0] == "PASS"
