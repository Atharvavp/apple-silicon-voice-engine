#!/usr/bin/env python3
"""Read-only audit of saved recording-granularity ASR traces for vanished open text.

Phase 1 follow-up, Step 0 (F04). Within one speech-swift native segment RNNT tokens only
append, and an EOU-confirmed final has no new tokens in its confirming chunk, so in an
intact segmented trace every recording partial is a character prefix of the next one and
the recording final equals the last partial. A suppressed native final leaves its open
text visible until the next segment's partial replaces it; that shows up here as a
non-prefix transition whose vanished tail is the open segment text.

The script only reads `events.jsonl`/`predictions.json` and writes one JSON result to
`--out` (which must not exist). It never writes inside the run directories.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def transcript_events(path: Path):
    with path.open("rb") as handle:
        for line in handle:
            if b'"transcript.' not in line:
                continue
            event = json.loads(line)
            if event["type"] in ("transcript.partial", "transcript.final"):
                yield event


def audit_run(run_dir: Path) -> dict:
    events = list(transcript_events(run_dir / "events.jsonl"))
    revisions = [e["payload"]["revision"] for e in events]
    if revisions != sorted(revisions) or len(set(revisions)) != len(revisions):
        raise SystemExit(f"{run_dir}: transcript revisions are not strictly increasing")
    partials = [e for e in events if e["type"] == "transcript.partial"]
    finals = [e for e in events if e["type"] == "transcript.final"]
    if len(finals) != 1 or events[-1] is not finals[0]:
        raise SystemExit(f"{run_dir}: expected exactly one trailing final")
    rollbacks = []
    previous = ""
    for event in partials:
        text = event["payload"]["text"]
        if not text.startswith(previous):
            common = os.path.commonprefix([previous, text])
            # Back up to a word boundary so the vanished tail is whole words.
            cut = common.rfind(" ") + 1 if not previous[len(common):].startswith(" ") else len(common)
            vanished = previous[cut:].strip()
            head = previous[:cut].strip().split()
            vanished_words = vanished.split()
            rollbacks.append({
                "revision": event["payload"]["revision"],
                "cause_chunk_index": event["cause_chunk_index"],
                "vanished_text": vanished,
                "vanished_words": len(vanished_words),
                # Mechanism check: the vanished open text equals the immediately preceding words,
                # i.e. it repeated the previous native final verbatim.
                "repeats_preceding_words": bool(vanished_words) and head[-len(vanished_words):] == vanished_words,
                "replacement_text": text[cut:].strip()[:80],
            })
        previous = text
    final_text = finals[0]["payload"]["text"]
    predictions = json.loads((run_dir / "predictions.json").read_text())
    return {
        "run": run_dir.name,
        "partial_events": len(partials),
        "rollback_count": len(rollbacks),
        "vanished_word_total": sum(r["vanished_words"] for r in rollbacks),
        "rollbacks_repeating_preceding_words": sum(r["repeats_preceding_words"] for r in rollbacks),
        "final_equals_last_partial": bool(partials) and final_text == partials[-1]["payload"]["text"],
        "final_equals_predictions_transcript": [u["text"] for u in predictions["transcript"]] == [final_text],
        "final_words": len(final_text.split()),
        "rollbacks": rollbacks,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=Path, nargs="+", required=True, help="run directories to audit")
    parser.add_argument("--out", type=Path, required=True, help="new JSON result file")
    args = parser.parse_args()
    if args.out.exists():
        print(f"refusing to overwrite {args.out}", file=sys.stderr)
        return 2
    result = {"audit": "asr_rollback_audit_v1", "runs": [audit_run(r) for r in args.runs]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    for run in result["runs"]:
        print(f"{run['run']}: partials={run['partial_events']} rollbacks={run['rollback_count']} "
              f"vanished_words={run['vanished_word_total']} repeat-mechanism={run['rollbacks_repeating_preceding_words']} "
              f"final==last_partial={run['final_equals_last_partial']} final==predictions={run['final_equals_predictions_transcript']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
