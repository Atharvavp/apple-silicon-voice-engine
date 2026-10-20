#!/usr/bin/env python3
"""Phase 1 dataset stage: freeze the AMI crop and its two references, write v1 manifests.

    .venv/bin/python scripts/prepare_phase1_data.py --inputs /abs/phase1-inputs.json \
        --voicebench .build/phase1-both/release/voicebench --out "$SESSION/datasets"

Selection happens before any model output exists and never looks at accuracy:
headset-mix ES2008a, first eligible contiguous prefix of 900-1200 s (target 1200 s); if that
meeting is unavailable or ineligible, the lexically first eligible meeting of the approved AMI
inventory. The crop end moves earlier only so that no timed word is cut (source annotations
only). Every input/output hash, the crop sample range and the extraction policy are recorded.

References (frozen before predictions, applied identically to both frameworks):
  * transcript (recording granularity): genuine lexical <w> words of all speakers ordered by
    (start time, speaker channel, word number), repeats/disfluencies/truncations kept,
    punctuation tokens and non-lexical elements excluded. This is a mono overlap
    linearization, not speaker-attributed WER and not the standard AMI ASR benchmark.
  * speakers ("derived_word_union_v1"): per speaker, the union of timed lexical word intervals,
    merged only where they overlap or touch; gaps are kept. Derived from manual word timing;
    NOT the standard AMI segmentation.
Missing lexical timing inside the crop blocks the affected reference instead of guessing.
Optional VoxConverse is processed only when the inputs supply lawful audio and RTTMs;
otherwise it is recorded as skipped_optional.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shlex
import struct
import subprocess
import sys
import wave
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
NITE = "{http://nite.sourceforge.net/}"
RATE = 16000
TARGET_S = Decimal(1200)
MINIMUM_S = Decimal(900)
PREFERRED_MEETING = "ES2008a"
TRANSCRIPT_POLICY = "ami_nxt_recording_text_v1"
SPEAKER_POLICY = "derived_word_union_v1"
# Elements of an AMI NXT words file that are not lexical words (excluded from both references).
NON_LEXICAL = {"vocalsound", "nonvocalsound", "disfmarker", "pause", "gap", "comment", "sil"}


@dataclass(frozen=True)
class Word:
    word_id: str
    agent: str
    start: Decimal | None
    end: Decimal | None
    text: str
    truncated: bool

    @property
    def number(self) -> int:
        match = re.search(r"(\d+)$", self.word_id)
        return int(match.group(1)) if match else -1


# --- parsing ----------------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def decimal_time(value: str | None, where: str) -> Decimal | None:
    if value is None:
        return None
    try:
        parsed = Decimal(value)
    except Exception as error:  # noqa: BLE001 - surfaced with location
        raise ValueError(f"{where}: unparseable time {value!r}") from error
    if not parsed.is_finite() or parsed < 0:
        raise ValueError(f"{where}: invalid time {value!r}")
    return parsed


def parse_words(data: bytes, agent: str, source: str) -> tuple[list[Word], dict[str, int]]:
    """Lexical words of one AMI NXT words file plus counts of every element kind seen.

    Unknown element kinds are an error: the converter must not guess what they mean.
    """
    root = ET.fromstring(data)
    words: list[Word] = []
    counts: dict[str, int] = {}
    for element in root:
        tag = element.tag.replace(NITE, "nite:")
        counts[tag] = counts.get(tag, 0) + 1
        if tag in NON_LEXICAL:
            continue
        if tag != "w":
            raise ValueError(f"{source}: unknown element <{tag}>; extend the documented policy before converting")
        if element.get("punc") == "true":
            counts["w(punc)"] = counts.get("w(punc)", 0) + 1
            continue
        word_id = element.get(f"{NITE}id")
        if not word_id:
            raise ValueError(f"{source}: <w> without nite:id")
        text = (element.text or "").strip()
        if not text:
            raise ValueError(f"{source}: word {word_id} has no text")
        where = f"{source}#{word_id}"
        words.append(Word(word_id=word_id, agent=agent, start=decimal_time(element.get("starttime"), where),
                          end=decimal_time(element.get("endtime"), where), text=text,
                          truncated=element.get("trunc") == "true"))
    return words, counts


def parse_meetings(data: bytes, meeting: str) -> dict[str, dict[str, str]]:
    """Agent letter -> attributes of <speaker> for one meeting in corpusResources/meetings.xml."""
    root = ET.fromstring(data)
    for element in root.iter():
        if element.tag.endswith("meeting") and element.get("observation") == meeting:
            speakers = {}
            for speaker in element:
                if speaker.tag.endswith("speaker"):
                    agent = speaker.get("nxt_agent")
                    if not agent:
                        raise ValueError(f"meetings.xml {meeting}: <speaker> without nxt_agent")
                    speakers[agent] = dict(speaker.attrib)
            if not speakers:
                raise ValueError(f"meetings.xml {meeting}: no speakers")
            return speakers
    raise ValueError(f"meetings.xml has no meeting {meeting}")


# --- time and selection -----------------------------------------------------------------------


def to_sample(seconds: Decimal, rate: int = RATE) -> int:
    """Exact decimal seconds -> nearest sample, halves rounded up (documented policy)."""
    return int((seconds * rate).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def precision_of(words: list[Word]) -> dict[str, Any]:
    """Coarsest unit that represents every source time exactly (never upgraded)."""
    places = 0
    for word in words:
        for value in (word.start, word.end):
            if value is not None:
                places = max(places, -value.as_tuple().exponent if value.as_tuple().exponent < 0 else 0)
    if places == 0:
        return {"unit": "s", "step": 1}
    if places <= 2:
        return {"unit": "cs", "step": 1}
    if places <= 3:
        return {"unit": "ms", "step": 1}
    return {"unit": "samples", "step": 1}


def timed_union(intervals: list[tuple[Decimal, Decimal]]) -> list[tuple[Decimal, Decimal]]:
    merged: list[list[Decimal]] = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(a, b) for a, b in merged]


def choose_end(words: list[Word], audio_seconds: Decimal, target: Decimal = TARGET_S,
               minimum: Decimal = MINIMUM_S) -> tuple[Decimal, str]:
    """Crop end <= min(target, audio length) that cuts no timed word; earliest allowed is `minimum`."""
    limit = min(target, audio_seconds)
    if limit < minimum:
        raise ValueError(f"recording is {audio_seconds} s; at least {minimum} s is required")
    intervals = [(w.start, w.end) for w in words if w.start is not None and w.end is not None and w.end > w.start]
    end = limit
    for start, stop in timed_union(intervals):
        if start < end < stop:
            end = start
            break
    if end < minimum:
        raise ValueError(f"no word-free boundary between {minimum} s and {limit} s")
    reason = "target" if end == target else ("audio_end" if end == audio_seconds else "moved_earlier_to_avoid_cutting_a_word")
    return end, reason


def words_in_crop(words: list[Word], end: Decimal) -> tuple[list[Word], list[str]]:
    """Timed words ending inside the crop; untimed words that cannot be placed are reported."""
    inside: list[Word] = []
    unplaced: list[str] = []
    by_agent: dict[str, list[Word]] = {}
    for word in words:
        by_agent.setdefault(word.agent, []).append(word)
    for agent_words in by_agent.values():
        for index, word in enumerate(agent_words):
            if word.start is not None and word.end is not None:
                if word.end <= end:
                    inside.append(word)
                elif word.start < end:
                    raise ValueError(f"word {word.word_id} crosses the crop end {end}")
                continue
            # Untimed lexical word: its timed neighbours in document order decide membership. It is
            # outside only when provably after the crop; otherwise it cannot be ordered honestly.
            before = next((w for w in reversed(agent_words[:index]) if w.end is not None), None)
            after = next((w for w in agent_words[index + 1:] if w.start is not None), None)
            if before is not None and before.end is not None and before.end > end:
                continue
            if before is None and after is not None and after.start is not None and after.start >= end:
                continue
            unplaced.append(word.word_id)
    return inside, sorted(unplaced)


def recording_text(words: list[Word], channel: dict[str, int]) -> str:
    ordered = sorted(words, key=lambda w: (w.start, channel[w.agent], w.number, w.word_id))
    return " ".join(w.text for w in ordered)


# --- documents --------------------------------------------------------------------------------


def header(kind: str, source_id: str, duration: int, precision: dict[str, Any]) -> dict[str, Any]:
    return {"schema_version": "1.0", "kind": kind, "source_id": source_id, "languages": ["en"],
            "timebase": {"unit": "samples", "sample_rate_hz": RATE}, "duration_samples": duration,
            "original_precision": precision, "coverage": [{"start_sample": 0, "end_sample": duration}]}


def transcript_document(source_id: str, duration: int, precision: dict[str, Any], text: str) -> dict[str, Any]:
    document = header("transcript", source_id, duration, precision)
    document.update({"granularity": "recording", "segments": [], "recording_text": text})
    return document


def speaker_document(source_id: str, duration: int, precision: dict[str, Any], words: list[Word]) -> dict[str, Any]:
    segments = []
    for agent in sorted({w.agent for w in words}):
        intervals = [(w.start, w.end) for w in words if w.agent == agent and w.end > w.start]
        for index, (start, end) in enumerate(timed_union(intervals)):
            first, last = to_sample(start), min(to_sample(end), duration)
            if last > first:
                segments.append({"segment_id": f"{agent}-{index:05d}", "speaker_id": agent,
                                 "start_sample": first, "end_sample": last})
    segments.sort(key=lambda s: (s["start_sample"], s["speaker_id"]))
    document = header("speakers", source_id, duration, precision)
    document["segments"] = segments
    return document


def canonical_bytes(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def descriptor_hash(transcript_sha: str | None, speakers_sha: str | None) -> str:
    return hashlib.sha256(f"{transcript_sha or '-'}\n{speakers_sha or '-'}\n".encode()).hexdigest()


def manifest(dataset_id: str, item_id: str, audio: Path, audio_sha: str, duration: int, reference_key: str,
             reference: Path, reference_sha: str, annotation_type: str, rights: dict[str, Any],
             notes: str) -> dict[str, Any]:
    transcript = reference_key == "transcript"
    item = {
        "item_id": item_id, "languages": ["en"], "split": "phase1-eval", "status": "ready",
        "audio_path": audio.name, "audio_sha256": audio_sha, "sample_rate_hz": RATE, "channels": 1,
        "duration_samples": duration,
        "reference_text_path": reference.name if transcript else None,
        "reference_text_sha256": reference_sha if transcript else None,
        "speaker_segments_path": None if transcript else reference.name,
        "speaker_segments_sha256": None if transcript else reference_sha,
        "reference_sha256": descriptor_hash(reference_sha if transcript else None, None if transcript else reference_sha),
        "fixture_script_path": None, "fixture_script_sha256": None,
        "annotation_type": annotation_type,
        "coverage": {"transcript": transcript, "speakers": not transcript, "joint_words": False},
        "rights_notes": rights["rights_notes"],
    }
    return {"schema_version": "1.0", "dataset_id": dataset_id, "version": rights["version"], "languages": ["en"],
            "source_name": rights["source_name"], "source_url": rights["source_url"], "license": rights["license"],
            "license_verified": True, "redistribution_allowed": rights["redistribution_allowed"],
            "external_root": None, "annotation_type": annotation_type, "status": "ready",
            "provenance_notes": notes, "items": [item]}


# --- audio ------------------------------------------------------------------------------------


def read_wav_info(path: Path) -> dict[str, Any]:
    with wave.open(str(path), "rb") as handle:
        return {"rate": handle.getframerate(), "channels": handle.getnchannels(), "sample_width": handle.getsampwidth(),
                "frames": handle.getnframes(), "compression": handle.getcomptype()}


def crop_wav(source: Path, destination: Path, end_sample: int, start_sample: int = 0) -> None:
    """Copies frames [start_sample, end_sample) byte-for-byte (no conversion, no resampling)."""
    with wave.open(str(source), "rb") as reader:
        if reader.getframerate() != RATE or reader.getnchannels() != 1 or reader.getcomptype() != "NONE":
            raise ValueError(f"{source}: expected 16 kHz mono PCM, got {reader.getframerate()} Hz/{reader.getnchannels()} ch")
        if reader.getnframes() < end_sample or not 0 <= start_sample < end_sample:
            raise ValueError(f"{source}: {reader.getnframes()} frames cannot supply [{start_sample}, {end_sample})")
        reader.setpos(start_sample)
        frames = reader.readframes(end_sample - start_sample)
        width = reader.getsampwidth()
    with destination.open("xb") as raw, wave.open(raw, "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(width)
        writer.setframerate(RATE)
        writer.writeframes(frames)


def rms(path: Path, start: int, end: int) -> float:
    with wave.open(str(path), "rb") as reader:
        width = reader.getsampwidth()
        if width != 2:
            raise ValueError("RMS check supports 16-bit PCM only")
        reader.setpos(start)
        data = reader.readframes(max(0, end - start))
    count = len(data) // 2
    if count == 0:
        return 0.0
    values = struct.unpack(f"<{count}h", data[: count * 2])
    return math.sqrt(sum(v * v for v in values) / count) / 32768.0


def acoustic_spot_check(audio: Path, speakers: dict[str, Any], duration: int) -> dict[str, Any]:
    """Automatic sanity check at start/middle/end: annotated speech should be louder than
    annotated silence in the mix. A gross offset or rate drift flips or flattens the ratio.
    This is evidence of alignment, not proof; no listening test is claimed."""
    windows = {}
    third = duration // 3
    for name, (lo, hi) in {"start": (0, third), "middle": (third, 2 * third), "end": (2 * third, duration)}.items():
        speech = timed_union_samples([(s["start_sample"], s["end_sample"]) for s in speakers["segments"]
                                      if s["start_sample"] < hi and s["end_sample"] > lo], lo, hi)
        silence = complement(speech, lo, hi)
        speech_rms = mean_rms(audio, speech)
        silence_rms = mean_rms(audio, [g for g in silence if g[1] - g[0] >= RATE // 2])
        windows[name] = {"speech_rms": speech_rms, "silence_rms": silence_rms,
                         "ratio": (speech_rms / silence_rms) if silence_rms > 0 else None}
    passed = all(w["ratio"] is None or w["ratio"] > 1.5 for w in windows.values())
    return {"performed": True, "method": "mix_rms_speech_vs_annotated_silence_v1", "threshold_ratio": 1.5,
            "windows": windows, "status": "pass" if passed else "fail",
            "listening_check_performed": False}


def timed_union_samples(ranges: list[tuple[int, int]], lo: int, hi: int) -> list[tuple[int, int]]:
    clipped = [(max(lo, a), min(hi, b)) for a, b in ranges if min(hi, b) > max(lo, a)]
    merged: list[list[int]] = []
    for a, b in sorted(clipped):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return [(a, b) for a, b in merged]


def complement(ranges: list[tuple[int, int]], lo: int, hi: int) -> list[tuple[int, int]]:
    gaps, cursor = [], lo
    for a, b in ranges:
        if a > cursor:
            gaps.append((cursor, a))
        cursor = max(cursor, b)
    if cursor < hi:
        gaps.append((cursor, hi))
    return gaps


def mean_rms(audio: Path, ranges: list[tuple[int, int]], limit: int = 40) -> float:
    picked = sorted(ranges, key=lambda r: r[1] - r[0], reverse=True)[:limit]
    values = [rms(audio, a, b) for a, b in picked]
    return sum(values) / len(values) if values else 0.0


# --- AMI stage ---------------------------------------------------------------------------------


def eligible_meetings(ami: dict[str, Any]) -> list[str]:
    inventory = sorted(ami["meeting_inventory"])
    return ([PREFERRED_MEETING] if PREFERRED_MEETING in inventory else []) + [m for m in inventory if m != PREFERRED_MEETING]


def prepare_ami(ami: dict[str, Any], voicebench: Path, out: Path, record: dict[str, Any]) -> dict[str, Any]:
    audio_root = Path(ami["audio_root"])
    annotations = Path(ami["annotations_root"])
    meetings_xml = annotations / "corpusResources/meetings.xml"
    exclusions: list[dict[str, str]] = []
    chosen = None
    for meeting in eligible_meetings(ami):
        audio = audio_root / meeting / "audio" / f"{meeting}.Mix-Headset.wav"
        try:
            if not audio.is_file():
                raise ValueError(f"headset mix {audio} not present")
            info = read_wav_info(audio)
            if info["rate"] != RATE or info["channels"] != 1:
                raise ValueError(f"headset mix is {info['rate']} Hz/{info['channels']} ch")
            speakers = parse_meetings(meetings_xml.read_bytes(), meeting)
            words: list[Word] = []
            element_counts: dict[str, dict[str, int]] = {}
            for agent in sorted(speakers):
                path = annotations / "words" / f"{meeting}.{agent}.words.xml"
                agent_words, counts = parse_words(path.read_bytes(), agent, path.name)
                words.extend(agent_words)
                element_counts[agent] = counts
            audio_seconds = Decimal(info["frames"]) / RATE
            end, reason = choose_end(words, audio_seconds)
            chosen = (meeting, audio, info, speakers, words, element_counts, end, reason)
            break
        except (OSError, ValueError, ET.ParseError) as error:
            exclusions.append({"meeting": meeting, "reason": str(error)})  # metadata-only exclusion
    record["ami_selection_exclusions"] = exclusions
    if chosen is None:
        raise RuntimeError(f"no eligible AMI meeting in the approved inventory: {exclusions}")
    meeting, audio, info, speakers, words, element_counts, end, reason = chosen
    end_sample = to_sample(end)
    inside, unplaced = words_in_crop(words, end)
    channel = {agent: int(attrs.get("channel", "99")) for agent, attrs in speakers.items()}
    precision = precision_of(inside)
    item_id = f"ami-{meeting}-mixheadset-0-{end_sample}"
    crop = out / f"{item_id}.wav"
    crop_wav(audio, crop, end_sample)
    duration = read_wav_info(crop)["frames"]
    assert duration == end_sample

    references: dict[str, Any] = {}
    asr_block = f"{len(unplaced)} untimed lexical words fall inside the crop: {unplaced[:10]}" if unplaced else None
    transcript_path = out / f"{item_id}.transcript.json"
    if asr_block is None:
        transcript_path.write_bytes(canonical_bytes(transcript_document(item_id, duration, precision,
                                                                          recording_text(inside, channel))))
        references["transcript"] = {"path": transcript_path.name, "sha256": sha256_file(transcript_path),
                                    "policy": TRANSCRIPT_POLICY, "words": len(inside)}
    speakers_path = out / f"{item_id}.speakers.json"
    speakers_doc = speaker_document(item_id, duration, precision, inside)
    speakers_path.write_bytes(canonical_bytes(speakers_doc))
    references["speakers"] = {"path": speakers_path.name, "sha256": sha256_file(speakers_path),
                              "policy": SPEAKER_POLICY, "segments": len(speakers_doc["segments"]),
                              "speaker_count": len({s["speaker_id"] for s in speakers_doc["segments"]})}
    crop_sha = sha256_file(crop)
    rights = {"version": ami["annotations_version"], "source_name": "AMI Meeting Corpus (headset mix, manual annotations)",
              "source_url": ami["source_url"], "license": ami["license"],
              "redistribution_allowed": ami.get("redistribution_allowed"),
              "rights_notes": f"{ami['license']}; local research use per owner approval ({ami['license_evidence']}); "
                              "crop and derived references are not redistributed by this project."}
    notes = (f"Meeting {meeting} headset mix, samples [0, {end_sample}) ({end} s, end reason {reason}). "
             f"Transcript {TRANSCRIPT_POLICY}: recording-text projection of verified manual words. "
             f"Speakers {SPEAKER_POLICY}: derived word-union activity, not standard AMI segmentation. "
             "Selected before any model output; Sortformer/Parakeet training exposure to AMI is possible.")
    manifests = {}
    if "transcript" in references:
        m = manifest(f"ami-{meeting.lower()}-asr", item_id, crop, crop_sha, duration, "transcript", transcript_path,
                     references["transcript"]["sha256"], "words", rights, notes)
        path = out / "ami-asr.manifest.json"
        path.write_bytes(canonical_bytes(m))
        manifests["asr"] = str(path)
    m = manifest(f"ami-{meeting.lower()}-diar", item_id, crop, crop_sha, duration, "speakers", speakers_path,
                 references["speakers"]["sha256"], "speaker_segments", rights, notes)
    path = out / "ami-diar.manifest.json"
    path.write_bytes(canonical_bytes(m))
    manifests["diarization"] = str(path)

    validations = {}
    for role, manifest_path in manifests.items():
        argv = [str(voicebench), "validate", "--dataset", manifest_path, "--require-ready"]
        result = subprocess.run(argv, capture_output=True, text=True, check=False)
        validations[role] = {"argv": argv, "exit_code": result.returncode, "stdout": result.stdout[-2000:],
                             "stderr": result.stderr[-2000:]}
    smoke = prepare_smoke(audio, info, meeting, end_sample, crop_sha, rights, out)
    spot = acoustic_spot_check(crop, speakers_doc, duration)
    overlap = overlap_seconds(speakers_doc)
    return {
        "dataset": "ami", "meeting": meeting, "item_id": item_id, "status": "ready",
        "source_audio": {"path": str(audio), "sha256": sha256_file(audio), **info},
        "crop": {"path": crop.name, "sha256": crop_sha, "start_sample": 0, "end_sample": end_sample,
                 "end_seconds": str(end), "end_reason": reason, "duration_samples": duration,
                 "extraction": "byte-exact frame copy of the 16 kHz mono headset mix prefix (Python wave); no SRC, "
                               "no denoising, no trimming; harness AudioPreparer bypasses conversion at 16 kHz"},
        "annotations": {"root": str(annotations), "version": ami["annotations_version"],
                        "meetings_xml_sha256": sha256_file(meetings_xml),
                        "words_files": {agent: sha256_file(annotations / "words" / f"{meeting}.{agent}.words.xml")
                                        for agent in sorted(speakers)},
                        "element_counts": element_counts, "speakers": speakers, "channel_order": channel},
        "time_policy": {"decimal_seconds_to_sample": "round_half_up(seconds * 16000)", "precision": precision},
        "references": references, "asr_reference_blocked": asr_block,
        "nonlexical_handling": f"excluded elements: {sorted(NON_LEXICAL)} and <w punc=\"true\">; "
                               "truncated words (trunc=\"true\") and repeats kept",
        "overlap_speech_seconds": overlap, "manifests": manifests, "validate_require_ready": validations,
        "acoustic_spot_check": spot, "smoke": smoke,
    }


SMOKE_SAMPLES = 60 * RATE


def prepare_smoke(audio: Path, info: dict[str, Any], meeting: str, end_sample: int, crop_sha: str,
                  rights: dict[str, Any], out: Path) -> dict[str, Any] | None:
    """Fixed 60 s smoke input taken right after the evaluation crop (disjoint from it), no references.
    Used only to prove loading/streaming/output before measured runs; never scored or counted."""
    if info["frames"] < end_sample + SMOKE_SAMPLES:
        return None
    item_id = f"ami-{meeting}-mixheadset-smoke-{end_sample}-{end_sample + SMOKE_SAMPLES}"
    path = out / f"{item_id}.wav"
    crop_wav(audio, path, end_sample + SMOKE_SAMPLES, start_sample=end_sample)
    sha = sha256_file(path)
    assert sha != crop_sha
    item = {"item_id": item_id, "languages": ["en"], "split": "phase1-smoke", "status": "ready", "audio_path": path.name,
            "audio_sha256": sha, "sample_rate_hz": RATE, "channels": 1, "duration_samples": SMOKE_SAMPLES,
            "reference_text_path": None, "reference_text_sha256": None, "speaker_segments_path": None,
            "speaker_segments_sha256": None, "reference_sha256": None, "fixture_script_path": None,
            "fixture_script_sha256": None, "annotation_type": "mixed",
            "coverage": {"transcript": False, "speakers": False, "joint_words": False},
            "rights_notes": rights["rights_notes"]}
    document = {"schema_version": "1.0", "dataset_id": f"ami-{meeting.lower()}-smoke", "version": rights["version"],
                "languages": ["en"], "source_name": rights["source_name"], "source_url": rights["source_url"],
                "license": rights["license"], "license_verified": True,
                "redistribution_allowed": rights["redistribution_allowed"], "external_root": None,
                "annotation_type": "mixed", "status": "ready",
                "provenance_notes": "Smoke-only item: the 60 s following the evaluation crop; no references, not scored.",
                "items": [item]}
    manifest_path = out / "ami-smoke.manifest.json"
    manifest_path.write_bytes(canonical_bytes(document))
    return {"manifest": str(manifest_path), "item_id": item_id, "sha256": sha,
            "start_sample": end_sample, "end_sample": end_sample + SMOKE_SAMPLES}


def overlap_seconds(speakers_doc: dict[str, Any]) -> float:
    events = []
    for s in speakers_doc["segments"]:
        events += [(s["start_sample"], 1), (s["end_sample"], -1)]
    active, last, total = 0, 0, 0
    for position, delta in sorted(events):
        if active >= 2:
            total += position - last
        active += delta
        last = position
    return round(total / RATE, 3)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--inputs", required=True, help="absolute path of the owner's phase1-inputs.json")
    parser.add_argument("--voicebench", required=True)
    parser.add_argument("--out", required=True, help="new directory (refused if it exists)")
    args = parser.parse_args()
    inputs_path = Path(args.inputs)
    if not inputs_path.is_absolute() or not inputs_path.is_file():
        print(f"inputs file {inputs_path} is not an existing absolute path; nothing prepared", file=sys.stderr)
        return 3
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    inputs = json.loads(inputs_path.read_text())
    record: dict[str, Any] = {"command": " ".join(shlex.quote(a) for a in sys.argv), "inputs_sha256": sha256_file(inputs_path),
                              "datasets": {}}
    status = 0
    ami = (inputs.get("datasets") or {}).get("ami")
    if not ami:
        record["datasets"]["ami"] = {"status": "blocked", "reason": "inputs supply no approved AMI audio/annotations"}
        status = 3
    else:
        try:
            record["datasets"]["ami"] = prepare_ami(ami, Path(args.voicebench).resolve(), out, record)
        except (OSError, ValueError, RuntimeError) as error:
            record["datasets"]["ami"] = {"status": "blocked", "reason": str(error)}
            status = 3
    vox = (inputs.get("datasets") or {}).get("voxconverse")
    record["datasets"]["voxconverse"] = ({"status": "skipped_optional",
                                          "reason": "no lawful local VoxConverse audio with matching v0.3 RTTMs supplied"}
                                         if not vox else {"status": "skipped_optional",
                                                          "reason": "VoxConverse conversion is not implemented in this "
                                                                    "packet; optional row not attempted"})
    with (out / "dataset-freeze.json").open("x") as handle:
        json.dump(record, handle, indent=2, default=str)
        handle.write("\n")
    print(json.dumps({k: v.get("status") for k, v in record["datasets"].items()}))
    return status


if __name__ == "__main__":
    sys.exit(main())
