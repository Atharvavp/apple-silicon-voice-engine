"""Gate A suite evaluation (plan G1/I1): reads ``<evidence>/acceptance/Vnn/result.json``
and returns a ``validation`` document (target kind ``suite``). Every V-ID must be
present and ``pass``; a missing result or a ``not_run`` check makes the suite
``incomplete`` and a failure makes it ``fail``. Nothing is re-run here."""

from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any

from .validate import now

V_IDS = [f"V{n:02d}" for n in range(1, 21)]


def evaluate(evidence: Path) -> dict[str, Any]:
    evidence = Path(evidence)
    checks, disclosures = [], []
    for vid in V_IDS:
        path = evidence / "acceptance" / vid / "result.json"
        if not path.exists():
            checks.append({"check_id": vid, "status": "not_run", "message": "no result recorded", "evidence": None})
            continue
        result = json.loads(path.read_text())
        failing = [c["name"] for c in result["commands"] if c["status"] != "pass"] + \
                  [c["name"] for c in result["checks"] if c["status"] != "pass"]
        status = {"pass": "pass", "fail": "fail"}.get(result["status"], "not_run")
        checks.append({"check_id": vid, "status": status,
                       "message": ("requirements " + ", ".join(result["requirement_ids"])
                                   + (f"; not passing: {failing}" if failing else "")),
                       "evidence": str(path)})
    performance = evidence / "performance" / "characterization.json"
    if performance.exists():
        data = json.loads(performance.read_text())
        if not data.get("controlled_idle_host", False):
            disclosures.append({"code": "uncontrolled_host",
                                "message": "P01-P03 were measured on an uncontrolled host; treat as provisional characterization"})
        if not data["P01"]["target_met_all_runs"]:
            disclosures.append({"code": "p01_target_missed",
                                "message": "P01 post-warm-up p95 exceeded 20 ms; owner approval is required for a warning-based release"})
    else:
        disclosures.append({"code": "performance_pending", "message": f"{performance} is missing"})
    statuses = [c["status"] for c in checks]
    status = "pass" if all(s == "pass" for s in statuses) else ("fail" if "fail" in statuses else "incomplete")
    return {"schema_version": "1.0", "validation_id": f"gate-a-{uuid.uuid4().hex[:12]}", "created_wall_time": now(),
            "target": {"kind": "suite", "path": str(evidence)}, "stage": None, "status": status, "checks": checks,
            "disclosures": disclosures}
