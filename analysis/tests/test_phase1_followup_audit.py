"""Phase 1 follow-up: the saved-trace ASR rollback audit flags the native A2 loss signatures.

The partial sequences are the ones the model-free native tests
(`Tests/SpeechNativeEOUTests`) observe from the unmodified speech-swift session, so together
they show the audit can detect F04a/F04b in a saved trace.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("asr_rollback_audit",
                                              ROOT / "scripts" / "phase1_followup" / "asr_rollback_audit.py")
audit = importlib.util.module_from_spec(spec)
sys.modules["asr_rollback_audit"] = audit
spec.loader.exec_module(audit)


def fake_run(tmp_path: Path, name: str, partials: list[str], final: str) -> Path:
    run = tmp_path / name
    run.mkdir()
    lines = [{"type": "adapter.started", "payload": {}}]
    texts = [(t, False) for t in partials] + [(final, True)]
    for revision, (text, is_final) in enumerate(texts, start=1):
        lines.append({"type": "transcript.final" if is_final else "transcript.partial", "cause_chunk_index": revision,
                      "payload": {"utterance_id": "recording", "revision": revision, "text": text, "is_final": is_final}})
    (run / "events.jsonl").write_text("".join(json.dumps(line) + "\n" for line in lines))
    (run / "predictions.json").write_text(json.dumps({"transcript": [{"utterance_id": "recording", "text": final}]}))
    return run


def test_intact_trace_has_no_rollback(tmp_path: Path) -> None:
    result = audit.audit_run(fake_run(tmp_path, "ok", ["yeah", "yeah okay", "yeah okay so"], "yeah okay so"))
    assert result["rollback_count"] == 0 and result["final_equals_last_partial"]
    assert result["final_equals_predictions_transcript"]


def test_suppressed_repeated_final_is_detected(tmp_path: Path) -> None:
    result = audit.audit_run(fake_run(tmp_path, "f04a", ["yeah", "yeah yeah", "yeah so"], "yeah so"))
    assert result["rollback_count"] == 1 and result["vanished_word_total"] == 1
    assert result["rollbacks"][0]["vanished_text"] == "yeah"
    assert result["rollbacks"][0]["repeats_preceding_words"]


def test_subword_extension_is_not_a_rollback(tmp_path: Path) -> None:
    result = audit.audit_run(fake_run(tmp_path, "sub", ["i", "i'", "i'll", "i'll go"], "i'll go"))
    assert result["rollback_count"] == 0


def test_trailing_chunk_loss_is_detected(tmp_path: Path) -> None:
    result = audit.audit_run(fake_run(tmp_path, "f04b", ["okay"], ""))
    assert result["rollback_count"] == 0
    assert not result["final_equals_last_partial"]
