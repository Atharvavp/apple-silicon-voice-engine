"""Phase 1 dataset stage: AMI NXT parsing, crop/timebase/hash goldens, v1-valid manifests."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import wave
from decimal import Decimal
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


data = load_script("prepare_phase1_data")

NXT = 'xmlns:nite="http://nite.sourceforge.net/"'


def words_xml(meeting: str, agent: str, body: str) -> bytes:
    return f'<?xml version="1.0"?><nite:root nite:id="{meeting}.{agent}.words" {NXT}>{body}</nite:root>'.encode()


def w(meeting: str, agent: str, n: int, start: str | None, end: str | None, text: str, **attrs: str) -> str:
    timing = (f' starttime="{start}"' if start else "") + (f' endtime="{end}"' if end else "")
    extra = "".join(f' {k}="{v}"' for k, v in attrs.items())
    return f'<w nite:id="{meeting}.{agent}.words{n}"{timing}{extra}>{text}</w>'


def test_parse_words_keeps_lexical_words_truncations_and_repeats_only():
    body = (w("M", "A", 0, "1.00", "1.20", "the") + w("M", "A", 1, "1.20", "1.40", "the")
            + '<disfmarker nite:id="M.A.words2" starttime="1.4" endtime="1.4"/>'
            + w("M", "A", 3, "1.40", "1.55", "th-", trunc="true") + w("M", "A", 4, "1.55", "1.55", ".", punc="true")
            + '<vocalsound nite:id="M.A.words5" starttime="2" endtime="2.5" type="laugh"/>')
    words, counts = data.parse_words(words_xml("M", "A", body), "A", "M.A.words.xml")
    assert [x.text for x in words] == ["the", "the", "th-"]
    assert words[2].truncated and counts["vocalsound"] == 1 and counts["disfmarker"] == 1 and counts["w(punc)"] == 1


def test_unknown_element_kind_is_an_error_not_a_guess():
    with pytest.raises(ValueError, match="unknown element"):
        data.parse_words(words_xml("M", "A", '<mystery nite:id="x"/>'), "A", "M.A.words.xml")


def test_recording_text_orders_by_start_channel_and_word_number():
    words = [data.Word("M.B.words1", "B", Decimal("1.0"), Decimal("1.2"), "beta", False),
             data.Word("M.A.words2", "A", Decimal("1.0"), Decimal("1.1"), "alpha", False),
             data.Word("M.A.words10", "A", Decimal("2.0"), Decimal("2.1"), "yes", False),
             data.Word("M.A.words9", "A", Decimal("2.0"), Decimal("2.0"), "yes", False)]
    assert data.recording_text(words, {"A": 0, "B": 1}) == "alpha beta yes yes"


def test_sample_rounding_is_exact_half_up_and_precision_is_never_upgraded():
    assert data.to_sample(Decimal("0.00003125")) == 1  # exactly 0.5 sample
    assert data.to_sample(Decimal("54.06")) == 864_960
    words = [data.Word("x0", "A", Decimal("1.5"), Decimal("1.25"), "a", False)]
    assert data.precision_of(words) == {"unit": "cs", "step": 1}


def test_crop_end_never_cuts_a_word_and_respects_the_minimum():
    words = [data.Word("x0", "A", Decimal("1199.5"), Decimal("1200.5"), "word", False),
             data.Word("x1", "B", Decimal("1199.0"), Decimal("1199.8"), "overlap", False)]
    end, reason = data.choose_end(words, Decimal(2000))
    assert end == Decimal("1199.0") and reason == "moved_earlier_to_avoid_cutting_a_word"
    assert data.choose_end([], Decimal(1000)) == (Decimal(1000), "audio_end")
    with pytest.raises(ValueError):
        data.choose_end([], Decimal(800))


def test_crop_end_moves_before_a_trailing_untimed_word():
    words = [data.Word("M.A.words0", "A", Decimal("1000.0"), Decimal("1041.14"), "okay", False),
             data.Word("M.A.words1", "A", None, None, "mm", False)]
    end, reason = data.choose_end(words, Decimal("1043.36"))
    assert end == Decimal("1000.0") or (end <= Decimal("1041.14") and reason == "moved_earlier_to_exclude_untimed_words")
    words = [data.Word("M.A.words0", "A", Decimal("1040.0"), Decimal("1041.14"), "okay", False),
             data.Word("M.A.words1", "A", None, None, "mm", False)]
    end, reason = data.choose_end(words, Decimal("1043.36"))
    assert (end, reason) == (Decimal("1040.0"), "moved_earlier_to_exclude_untimed_words")
    inside, unplaced = data.words_in_crop(words, end)
    assert unplaced == [] and inside == []


def test_untimed_word_inside_the_crop_blocks_instead_of_guessing():
    words = [data.Word("M.A.words0", "A", Decimal(1), Decimal(2), "a", False),
             data.Word("M.A.words1", "A", None, None, "b", False),
             data.Word("M.A.words2", "A", Decimal(3), Decimal(4), "c", False),
             data.Word("M.A.words3", "A", Decimal(20), Decimal(21), "d", False),
             data.Word("M.A.words4", "A", None, None, "e", False)]
    inside, unplaced = data.words_in_crop(words, Decimal(10))
    assert [x.text for x in inside] == ["a", "c"] and unplaced == ["M.A.words1"]


def test_word_union_speaker_reference_keeps_gaps_and_overlap():
    words = [data.Word("a0", "A", Decimal("0.0"), Decimal("1.0"), "x", False),
             data.Word("a1", "A", Decimal("1.0"), Decimal("1.5"), "y", False),
             data.Word("a2", "A", Decimal("2.0"), Decimal("2.5"), "z", False),
             data.Word("b0", "B", Decimal("1.2"), Decimal("3.0"), "w", False)]
    document = data.speaker_document("item", 40_000, {"unit": "cs", "step": 1}, words)
    spans = [(s["speaker_id"], s["start_sample"], s["end_sample"]) for s in document["segments"]]
    assert spans == [("A", 0, 24_000), ("B", 19_200, 40_000), ("A", 32_000, 40_000)]


def write_wav(path: Path, seconds: int, bursts: list[tuple[float, float]]) -> None:
    frames = bytearray(seconds * data.RATE * 2)
    loud = (8000).to_bytes(2, "little", signed=True) + (-8000).to_bytes(2, "little", signed=True)
    for start, end in bursts:
        a, b = int(start * data.RATE) * 2, int(end * data.RATE) * 2
        frames[a:b] = loud * ((b - a) // 4)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(data.RATE)
        handle.writeframes(bytes(frames))


@pytest.fixture(scope="module")
def ami_tree(tmp_path_factory: pytest.TempPathFactory) -> dict:
    root = tmp_path_factory.mktemp("ami")
    meeting = "ES2008a"
    (root / "audio" / meeting / "audio").mkdir(parents=True)
    (root / "manual" / "corpusResources").mkdir(parents=True)
    (root / "manual" / "words").mkdir()
    bursts = [(10 + 20 * i, 14 + 20 * i) for i in range(52)]  # speech every 20 s up to ~1050 s
    write_wav(root / "audio" / meeting / "audio" / f"{meeting}.Mix-Headset.wav", 1300, bursts)
    (root / "manual/corpusResources/meetings.xml").write_text(
        f'<?xml version="1.0"?><nite:root {NXT}><meeting observation="{meeting}">'
        '<speaker nxt_agent="A" global_name="FEE001" channel="0"/><speaker nxt_agent="B" global_name="MEE002" channel="1"/>'
        "</meeting></nite:root>")
    for agent, offset in (("A", 0.0), ("B", 2.0)):
        body = ""
        for i, (start, end) in enumerate(bursts):
            if i % 2 == (0 if agent == "A" else 1):
                body += w(meeting, agent, i, f"{start + offset / 2:.2f}", f"{end:.2f}", "okay" if i % 3 else "yeah")
        (root / "manual/words" / f"{meeting}.{agent}.words.xml").write_bytes(words_xml(meeting, agent, body))
    return {"audio_root": str(root / "audio"), "annotations_root": str(root / "manual"),
            "annotations_version": "1.6.2-test", "source_url": "https://groups.inf.ed.ac.uk/ami/download/",
            "license": "CC-BY-4.0", "license_evidence": "test fixture", "redistribution_allowed": None,
            "meeting_inventory": ["ES2008a", "ES2002a"]}


def test_prepare_ami_writes_v1_valid_role_manifests_and_a_disjoint_smoke(ami_tree: dict, voicebench: Path,
                                                                          tmp_path: Path):
    out = tmp_path / "datasets"
    out.mkdir()
    record = data.prepare_ami(ami_tree, voicebench, out, {})
    assert record["status"] == "ready" and record["crop"]["end_sample"] == 1200 * data.RATE
    assert record["crop"]["end_reason"] == "target"
    for role in ("asr", "diarization"):
        assert record["validate_require_ready"][role]["exit_code"] == 0, record["validate_require_ready"][role]
    asr = json.loads(Path(record["manifests"]["asr"]).read_text())["items"][0]
    diar = json.loads(Path(record["manifests"]["diarization"]).read_text())["items"][0]
    assert asr["audio_sha256"] == diar["audio_sha256"] == record["crop"]["sha256"]
    assert asr["speaker_segments_path"] is None and diar["reference_text_path"] is None
    assert asr["fixture_script_path"] is None and diar["fixture_script_path"] is None
    transcript = json.loads((out / asr["reference_text_path"]).read_text())
    assert transcript["granularity"] == "recording" and transcript["segments"] == []
    assert transcript["recording_text"].split()[:3] == ["yeah", "okay", "okay"]
    assert record["acoustic_spot_check"]["status"] == "pass"
    assert record["acoustic_spot_check"]["listening_check_performed"] is False
    smoke = record["smoke"]
    assert smoke["start_sample"] == record["crop"]["end_sample"] and smoke["sha256"] != record["crop"]["sha256"]
    result = subprocess.run([str(voicebench), "validate", "--dataset", smoke["manifest"], "--require-ready"],
                            capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    with wave.open(str(out / record["crop"]["path"]), "rb") as crop, \
            wave.open(str(Path(ami_tree["audio_root"]) / "ES2008a/audio/ES2008a.Mix-Headset.wav"), "rb") as source:
        assert crop.readframes(crop.getnframes()) == source.readframes(record["crop"]["end_sample"])


def test_prepare_refuses_an_existing_output_and_a_missing_inputs_file(tmp_path: Path, voicebench: Path):
    script = ROOT / "scripts/prepare_phase1_data.py"
    result = subprocess.run([sys.executable, str(script), "--inputs", str(tmp_path / "missing.json"), "--voicebench",
                             str(voicebench), "--out", str(tmp_path / "out")], capture_output=True, text=True, check=False)
    assert result.returncode == 3 and not (tmp_path / "out").exists()
    inputs = tmp_path / "inputs.json"
    inputs.write_text(json.dumps({"inputs_version": 1, "datasets": {}}))
    existing = tmp_path / "exists"
    existing.mkdir()
    result = subprocess.run([sys.executable, str(script), "--inputs", str(inputs), "--voicebench", str(voicebench),
                             "--out", str(existing)], capture_output=True, text=True, check=False)
    assert result.returncode != 0 and "File exists" in result.stderr
    result = subprocess.run([sys.executable, str(script), "--inputs", str(inputs), "--voicebench", str(voicebench),
                             "--out", str(tmp_path / "fresh")], capture_output=True, text=True, check=False)
    freeze = json.loads((tmp_path / "fresh/dataset-freeze.json").read_text())
    assert result.returncode == 3 and freeze["datasets"]["ami"]["status"] == "blocked"
    assert freeze["datasets"]["voxconverse"]["status"] == "skipped_optional"
