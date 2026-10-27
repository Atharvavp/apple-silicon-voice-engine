#!/usr/bin/env python3
"""Read-only DER sensitivity to a uniform reference shift (diagnostic only; never used to
choose or edit a reference). Positive shift moves the reference later; UEM stays the full
crop; pyannote re-optimizes the speaker mapping at each shift. Same scoring policy as the
campaign (collar 0, overlap scored). Writes one new JSON file outside the campaign packet.
"""
import json
import sys
from pathlib import Path

from pyannote.core import Annotation, Segment, Timeline
from pyannote.metrics.diarization import DiarizationErrorRate

RATE = 16000
SHIFTS = (-1.0, -0.25, -0.16, -0.08, 0.0, 0.08, 0.16, 0.25, 1.0)


def annotation(segments, shift=0.0):
    a = Annotation()
    for s in segments:
        a[Segment(s["start_sample"] / RATE + shift, s["end_sample"] / RATE + shift)] = s["speaker_id"]
    return a


def main() -> int:
    runs_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
    if out.exists():
        print(f"refusing to overwrite {out}", file=sys.stderr)
        return 2
    result = {}
    for run in sys.argv[3:]:
        hyp = annotation(json.loads((runs_dir / run / "predictions.json").read_text())["speakers"])
        ref = json.loads((runs_dir / run / "references" / "speakers.json").read_text())
        uem = Timeline([Segment(0, ref["duration_samples"] / RATE)])
        result[run] = {str(sh): round(DiarizationErrorRate(collar=0.0, skip_overlap=False)(annotation(ref["segments"], sh), hyp, uem=uem), 6)
                       for sh in SHIFTS}
        print(run, result[run])
    out.write_text(json.dumps({"diagnostic": "der_uniform_reference_shift_v1", "shifts_s": SHIFTS, "der": result}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
