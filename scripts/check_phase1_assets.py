#!/usr/bin/env python3
"""Check locally supplied Phase 1 model files against a published evidence packet (read-only).

    .venv/bin/python scripts/check_phase1_assets.py \
        docs/phase1/evidence/20261021-s2/provenance.json /ABSOLUTE/PATH/phase1-inputs.json

Every file the historical campaign profile listed must exist under the row's `root` with the same
SHA-256. A pass means the bytes match the 20261021-s2 models; it says nothing about licenses, which
you must read and accept yourself.
"""
import hashlib, json, sys
from pathlib import Path
packet, inputs = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
bad = 0
for profile in packet["profiles"]:
    root = Path(inputs["models"][profile["adapter_id"]]["root"])
    for f in profile["model"]["files"]:
        p = root / f["path"]
        ok = p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == f["sha256"]
        bad += not ok
        if not ok: print("MISMATCH or missing:", p)
    print(profile["adapter_id"], "checked", len(profile["model"]["files"]), "files")
print("all model files match the 20261021-s2 profiles" if not bad else f"{bad} problems"); sys.exit(1 if bad else 0)
