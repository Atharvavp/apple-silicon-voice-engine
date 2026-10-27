#!/usr/bin/env python3
"""Deterministic WAV fixture generator (plan M2 task 1, V01-V04 inputs).

Writes RIFF/WAVE bytes directly (stdlib ``wave`` cannot write IEEE float or
WAVE_FORMAT_EXTENSIBLE), plus deliberately malformed files, a generation
manifest with SHA-256 per file, and independently computed count goldens
(``testdata/goldens/audio-counts.json``) using plain Python integer math.

These signals test infrastructure only (decode, downmix, conversion, sample
accounting). They are not speech and validate no recognition quality.

    generate_fixtures.py --small --out datasets/fixtures            # (re)write
    generate_fixtures.py --small --out datasets/fixtures --verify   # regenerate in memory and compare
    generate_fixtures.py --long-seconds 720 --out datasets/fixtures/generated-large   # M7 drift input (uncommitted)

``--small`` also writes the Gate A synthetic items (``audio/synthetic/*.wav``) and
``datasets/manifests/synthetic.json``. Their references (``annotations/``) and
mock prediction scripts (``scripts/``) are hand-authored JSON committed beside
them; the generator only hashes those files into the manifest, it never writes them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

GENERATOR_VERSION = "fixtures_v1"
ROOT = Path(__file__).resolve().parents[1]
GOLDENS = ROOT / "testdata/goldens/audio-counts.json"
TARGET_RATE = 16_000
FRAME_MS = (10, 20, 40, 80)

PCM = 0x0001
FLOAT = 0x0003
EXTENSIBLE = 0xFFFE
GUID_TAIL = bytes.fromhex("000000001000800000aa00389b71")


# ---------------------------------------------------------------- encoding --

def quantize(value: float, bits: int) -> int:
    """Float in [-1, 1] -> signed integer code (round half away from zero, clipped)."""
    scale = 1 << (bits - 1)
    code = int(math.floor(abs(value) * scale + 0.5)) * (1 if value >= 0 else -1)
    return max(-scale, min(scale - 1, code))


def encode_frames(channels: list[list[float | int]], bits: int, fmt: int) -> bytes:
    """Interleaves channels. Integer formats accept either floats (quantized) or exact int codes."""
    frames = len(channels[0])
    assert all(len(c) == frames for c in channels)
    out = bytearray()
    for i in range(frames):
        for channel in channels:
            sample = channel[i]
            if fmt == FLOAT:
                out += struct.pack("<f", float(sample))
            else:
                code = sample if isinstance(sample, int) else quantize(sample, bits)
                out += code.to_bytes(bits // 8, "little", signed=True)
    return bytes(out)


def fmt_chunk(fmt: int, channels: int, rate: int, bits: int, *, extensible_subformat: int | None = None,
              block_align: int | None = None, byte_rate: int | None = None, guid_override: bytes | None = None) -> bytes:
    align = block_align if block_align is not None else channels * bits // 8
    rate_bytes = byte_rate if byte_rate is not None else rate * channels * bits // 8
    tag = EXTENSIBLE if extensible_subformat is not None else fmt
    body = struct.pack("<HHIIHH", tag, channels, rate, rate_bytes, align, bits)
    if extensible_subformat is not None:
        guid = guid_override if guid_override is not None else struct.pack("<H", extensible_subformat) + GUID_TAIL
        mask = 0x4 if channels == 1 else 0x3
        body += struct.pack("<HHI", 22, bits, mask) + guid
    elif fmt == FLOAT:
        body += struct.pack("<H", 0)
    return b"fmt " + struct.pack("<I", len(body)) + body


def chunk(tag: bytes, payload: bytes) -> bytes:
    pad = b"\x00" if len(payload) % 2 else b""
    return tag + struct.pack("<I", len(payload)) + payload + pad


def riff(*chunks: bytes, form: bytes = b"WAVE", magic: bytes = b"RIFF", size_override: int | None = None) -> bytes:
    body = form + b"".join(chunks)
    size = size_override if size_override is not None else len(body)
    return magic + struct.pack("<I", size) + body


def wav(channels: list[list[float | int]], rate: int, bits: int, fmt: int, **kw) -> bytes:
    return riff(fmt_chunk(fmt, len(channels), rate, bits, **kw), chunk(b"data", encode_frames(channels, bits, fmt)))


# ----------------------------------------------------------------- signals --

def tone(freq: float, rate: int, frames: int, amplitude: float) -> list[float]:
    return [amplitude * math.sin(2.0 * math.pi * freq * n / rate) for n in range(frames)]


def impulse(frames: int, at: int, value: float = 1.0) -> list[float]:
    data = [0.0] * frames
    data[at] = value
    return data


def ramp(frames: int) -> list[float]:
    """Deterministic non-periodic ramp so misplaced or duplicated samples are visible."""
    return [((n * 37) % 2001 - 1000) / 1000.0 * 0.5 for n in range(frames)]


# ------------------------------------------------------------------ catalog --

def valid_fixtures() -> dict[str, dict]:
    """name -> {bytes, rate, channels, bits, encoding, frames, purpose}."""
    fx: dict[str, dict] = {}

    def add(name, channels, rate, bits, fmt, purpose, **kw):
        encoding = {PCM: f"pcm_s{bits}le", FLOAT: "float32le"}[fmt]
        if kw.get("extensible_subformat") is not None:
            encoding = "extensible_" + encoding
        fx[name] = {"bytes": wav(channels, rate, bits, fmt, **kw), "sample_rate_hz": rate,
                    "channels": len(channels), "bits_per_sample": bits, "encoding": encoding,
                    "frames": len(channels[0]), "purpose": purpose}

    add("mono16k_pcm16_tone440_1s", [tone(440, 16_000, 16_000, 0.5)], 16_000, 16, PCM, "canonical-rate PCM16 tone")
    add("mono16k_pcm16_final_partial", [ramp(16_100)], 16_000, 16, PCM,
        "16100 frames: 50 full 20 ms chunks + one 100-sample final partial")
    add("mono16k_pcm16_silence_0p5s", [[0.0] * 8_000], 16_000, 16, PCM, "silence")
    add("mono16k_pcm16_one_sample", [[0.25]], 16_000, 16, PCM, "single-frame clip")
    add("mono16k_pcm16_short_319", [ramp(319)], 16_000, 16, PCM, "shorter than one 20 ms frame")
    add("mono16k_pcm16_empty", [[]], 16_000, 16, PCM, "structurally valid zero-frame WAV")
    add("mono16k_f32_impulse", [impulse(8_000, 4_000)], 16_000, 32, FLOAT, "same-rate float impulse (bypass exactness)")
    add("mono16k_pcm16_fullscale", [[0, 32767, -32768, 1, -1, 16384, -16384]], 16_000, 16, PCM, "PCM16 scaling codes")
    add("mono16k_pcm24_fullscale", [[0, 8388607, -8388608, 1, -1, 4194304, -4194304]], 16_000, 24, PCM,
        "PCM24 scaling codes")
    add("mono16k_pcm32_fullscale", [[0, 2147483647, -2147483648, 1, -1, 1073741824, -1073741824]], 16_000, 32, PCM,
        "PCM32 scaling codes")
    add("mono16k_f32_outside_unit", [[0.0, 1.5, -2.0, 0.125]], 16_000, 32, FLOAT,
        "finite float samples outside [-1, 1] must not be clipped")
    add("stereo16k_pcm16_cancel", [tone(300, 16_000, 4_000, 0.5), [-v for v in tone(300, 16_000, 4_000, 0.5)]],
        16_000, 16, PCM, "L = -R: arithmetic mean downmix cancels")
    add("stereo16k_f32_dc", [[0.25] * 4_000, [0.75] * 4_000], 16_000, 32, FLOAT, "L=0.25, R=0.75: mean is 0.5")
    add("stereo48k_pcm24_tone1k", [tone(1000, 48_000, 48_000, 0.5)] * 2, 48_000, 24, PCM,
        "stereo 48 kHz PCM24 in-band tone")
    add("mono48k_f32_tone1k", [tone(1000, 48_000, 48_000, 0.5)], 48_000, 32, FLOAT, "in-band RMS preservation")
    add("mono48k_f32_tone12k", [tone(12_000, 48_000, 48_000, 0.5)], 48_000, 32, FLOAT,
        "above 16 kHz Nyquist: must be attenuated")
    add("mono48k_f32_dc", [[0.25] * 48_000], 48_000, 32, FLOAT, "DC preservation")
    add("mono48k_f32_impulse", [impulse(48_000, 24_000)], 48_000, 32, FLOAT, "SRC alignment probe")
    add("mono44k1_pcm16_tone1k", [tone(1000, 44_100, 44_100, 0.5)], 44_100, 16, PCM, "noncanonical 44.1 kHz input")
    add("mono44k1_pcm16_odd", [ramp(44_101)], 44_100, 16, PCM, "44.1 kHz odd length (endpoint rounding)")
    add("mono22k05_pcm16_ramp", [ramp(22_050)], 22_050, 16, PCM, "22.05 kHz input (10 ms not integral at source rate)")
    for name, rate, frames in (("mono44k1_f32_len1", 44_100, 1), ("mono44k1_f32_len7", 44_100, 7),
                               ("mono22k05_f32_len2", 22_050, 2), ("mono96k_f32_len3", 96_000, 3),
                               ("mono11k025_f32_len10", 11_025, 10), ("mono48k_f32_len5", 48_000, 5)):
        add(name, [ramp(frames)], rate, 32, FLOAT, f"very short input ({frames} frames) at a {rate} Hz source rate")
    add("mono16k_ext_pcm16", [ramp(1_000)], 16_000, 16, PCM, "WAVE_FORMAT_EXTENSIBLE PCM GUID",
        extensible_subformat=PCM)
    add("mono16k_ext_f32", [ramp(1_000)], 16_000, 32, FLOAT, "WAVE_FORMAT_EXTENSIBLE IEEE float GUID",
        extensible_subformat=FLOAT)
    return fx


def malformed_fixtures() -> dict[str, dict]:
    """name -> {bytes, expected_error, purpose}. expected_error names the WAVInspector error case."""
    data16 = encode_frames([ramp(100)], 16, PCM)
    good_fmt = fmt_chunk(PCM, 1, 16_000, 16)
    m: dict[str, dict] = {}

    def add(name, payload, expected, purpose):
        m[name] = {"bytes": payload, "expected_error": expected, "purpose": purpose}

    add("not_riff", b"this is not audio, just a renamed text file\n", "notRIFF", "renamed non-WAV")
    add("truncated_header", riff(good_fmt, chunk(b"data", data16))[:20], "truncated", "file ends inside fmt chunk")
    add("riff_not_wave", riff(good_fmt, chunk(b"data", data16), form=b"AVI "), "notWAVE", "RIFF form is not WAVE")
    add("rf64", riff(good_fmt, chunk(b"data", data16), magic=b"RF64"), "unsupportedContainer", "RF64 container")
    add("truncated_data", riff(good_fmt, chunk(b"data", data16))[:-40], "truncated", "data chunk cut short")
    add("missing_fmt", riff(chunk(b"data", data16)), "missingFormatChunk", "no fmt chunk")
    add("missing_data", riff(good_fmt), "missingDataChunk", "no data chunk")
    add("compressed_adpcm", riff(fmt_chunk(0x0002, 1, 16_000, 4, block_align=256, byte_rate=8000),
                                 chunk(b"data", b"\x00" * 256)), "unsupportedEncoding", "MS ADPCM")
    add("mulaw", riff(fmt_chunk(0x0007, 1, 8_000, 8), chunk(b"data", b"\xff" * 100)), "unsupportedEncoding", "mu-law")
    add("pcm8_unsigned", riff(fmt_chunk(PCM, 1, 16_000, 8), chunk(b"data", b"\x80" * 100)), "unsupportedEncoding",
        "8-bit PCM is outside the v1 matrix")
    add("float64", riff(fmt_chunk(FLOAT, 1, 16_000, 64), chunk(b"data", b"\x00" * 64)), "unsupportedEncoding",
        "64-bit float is outside the v1 matrix")
    add("three_channels", riff(fmt_chunk(PCM, 3, 16_000, 16), chunk(b"data", encode_frames([ramp(10)] * 3, 16, PCM))),
        "unsupportedChannelCount", "more than two channels")
    add("zero_channels", riff(fmt_chunk(PCM, 0, 16_000, 16, block_align=0, byte_rate=0), chunk(b"data", b"")),
        "invalidFormat", "zero channels")
    add("zero_sample_rate", riff(fmt_chunk(PCM, 1, 0, 16), chunk(b"data", data16)), "invalidFormat", "zero rate")
    add("bad_block_align", riff(fmt_chunk(PCM, 1, 16_000, 16, block_align=3), chunk(b"data", data16)),
        "invalidFormat", "block align inconsistent with channels*bits")
    add("bad_byte_rate", riff(fmt_chunk(PCM, 1, 16_000, 16, byte_rate=1234), chunk(b"data", data16)),
        "invalidFormat", "byte rate inconsistent")
    add("data_not_frame_aligned", riff(good_fmt, chunk(b"data", b"\x01\x02\x03")), "invalidFormat",
        "data length not a multiple of block align")
    add("extensible_unknown_guid", riff(fmt_chunk(PCM, 1, 16_000, 16, extensible_subformat=PCM,
                                                  guid_override=b"\x11" * 16), chunk(b"data", data16)),
        "unsupportedEncoding", "unknown extensible subformat")
    add("float_nan", riff(fmt_chunk(FLOAT, 1, 16_000, 32), chunk(b"data", struct.pack("<fff", 0.0, math.nan, 0.5))),
        "nonFiniteSample", "NaN sample in float WAV")
    add("float_inf", riff(fmt_chunk(FLOAT, 1, 16_000, 32), chunk(b"data", struct.pack("<ff", math.inf, 0.0))),
        "nonFiniteSample", "Inf sample in float WAV")
    return m


# ------------------------------------------------------------------ goldens --

def converted_frames(n_in: int, rate_in: int, rate_out: int) -> int:
    """Plan D2 item 5: floor((Nin * Rout + floor(Rin / 2)) / Rin); same rate bypasses."""
    if rate_in == rate_out:
        return n_in
    return (n_in * rate_out + rate_in // 2) // rate_in


def chunk_plan(total: int, rate: int, frame_ms: int) -> dict:
    if (rate * frame_ms) % 1000:
        return {"frame_ms": frame_ms, "valid": False}
    size = rate * frame_ms // 1000
    full, rem = divmod(total, size)
    return {"frame_ms": frame_ms, "valid": True, "frame_samples": size, "chunks": full + (1 if rem else 0),
            "final_chunk_samples": rem if rem else (size if full else 0),
            "final_end_sample": total,
            "final_deadline_ns": (total * 1_000_000_000) // rate}


def goldens(valid: dict[str, dict]) -> dict:
    out = {}
    for name, f in sorted(valid.items()):
        n_out = converted_frames(f["frames"], f["sample_rate_hz"], TARGET_RATE)
        out[name] = {"source_frames": f["frames"], "source_rate_hz": f["sample_rate_hz"], "channels": f["channels"],
                     "target_rate_hz": TARGET_RATE, "converted_frames": n_out,
                     "source_rate_chunking": [chunk_plan(f["frames"], f["sample_rate_hz"], ms) for ms in FRAME_MS],
                     "chunking": [chunk_plan(n_out, TARGET_RATE, ms) for ms in FRAME_MS]}
    return {"generator_version": GENERATOR_VERSION, "rule": "floor((Nin*Rout + floor(Rin/2)) / Rin)",
            "deadline_rule": "floor(end_sample * 1e9 / rate) (end-of-frame availability)", "fixtures": out}


# ---------------------------------------------------------- synthetic items --

MANIFESTS = ROOT / "datasets/manifests"
SYNTHETIC_RIGHTS = "Project-generated synthetic fixture (tones and silence, not speech); no third-party content. MIT License (see LICENSE)."


def segmented_tone(rate: int, frames: int, segments: list[tuple[int, int, float]], amplitude: float) -> list[float]:
    """Silence except a tone of the given frequency inside each [start, end) segment."""
    data = [0.0] * frames
    for start, end, freq in segments:
        for n in range(start, end):
            data[n] = amplitude * math.sin(2.0 * math.pi * freq * (n - start) / rate)
    return data


def synthetic_items() -> list[dict]:
    """Gate A pipeline items. Signals stand in for two speakers; the mocks never inspect them."""
    en = segmented_tone(16_000, 192_000, [(0, 64_000, 220.0), (64_000, 128_000, 330.0)], 0.3)
    hi_left = segmented_tone(48_000, 384_000, [(0, 192_000, 220.0), (192_000, 384_000, 330.0)], 0.3)
    hi_right = [0.5 * v for v in hi_left]
    trim = tone(300.0, 22_050, 22_049, 0.25)
    return [
        {"item_id": "two-speaker-en", "languages": ["en"], "rate": 16_000, "channels": [en], "bits": 16, "fmt": PCM,
         "purpose": "16 kHz mono PCM16 (conversion bypassed); WER/CER/DER/JER with known errors"},
        {"item_id": "two-speaker-hi", "languages": ["hi-IN"], "rate": 48_000, "channels": [hi_left, hi_right],
         "bits": 16, "fmt": PCM,
         "purpose": "48 kHz stereo PCM16: downmix + exact 3:1 SRC; Devanagari scoring; references at the source rate"},
        {"item_id": "endpoint-trim-en", "languages": ["en"], "rate": 22_050, "channels": [trim], "bits": 32,
         "fmt": FLOAT,
         "purpose": "22,049 frames at 22.05 kHz: AVAudioConverter emits one extra frame, so allow_one_frame_v1 trims it (DEC-026 disclosure)"},
    ]


def synthetic_outputs(out: Path) -> dict[Path, bytes]:
    files: dict[Path, bytes] = {}
    items = []
    for spec in synthetic_items():
        item_id = spec["item_id"]
        audio = wav(spec["channels"], spec["rate"], spec["bits"], spec["fmt"])
        audio_path = out / f"audio/synthetic/{item_id}.wav"
        files[audio_path] = audio
        transcript = out / f"annotations/{item_id}.transcript.json"
        speakers = out / f"annotations/{item_id}.speakers.json"
        script = out / f"scripts/{item_id}.json"
        t_hash, s_hash, x_hash = (hashlib.sha256(p.read_bytes()).hexdigest() for p in (transcript, speakers, script))
        rel = lambda p: "../" + str(p.relative_to(ROOT / "datasets"))
        items.append({
            "item_id": item_id, "languages": spec["languages"], "split": "synthetic-test", "status": "ready",
            "audio_path": rel(audio_path), "audio_sha256": hashlib.sha256(audio).hexdigest(),
            "sample_rate_hz": spec["rate"], "channels": len(spec["channels"]),
            "duration_samples": len(spec["channels"][0]),
            "reference_text_path": rel(transcript), "reference_text_sha256": t_hash,
            "speaker_segments_path": rel(speakers), "speaker_segments_sha256": s_hash,
            "reference_sha256": hashlib.sha256(f"{t_hash}\n{s_hash}\n".encode()).hexdigest(),
            "fixture_script_path": rel(script), "fixture_script_sha256": x_hash,
            "annotation_type": "mixed",
            "coverage": {"transcript": True, "speakers": True, "joint_words": False},
            "rights_notes": SYNTHETIC_RIGHTS + " Purpose: " + spec["purpose"] + ".",
        })
    manifest = {
        "schema_version": "1.0", "dataset_id": "phase0-synthetic", "version": "1", "languages": ["en", "hi-IN"],
        "source_name": "project_generated", "source_url": None,
        "license": "MIT (project-authored synthetic data; see LICENSE)",
        "license_verified": True, "redistribution_allowed": True, "external_root": None, "annotation_type": "mixed",
        "status": "ready",
        "provenance_notes": "Audio generated by scripts/generate_fixtures.py (" + GENERATOR_VERSION + "); references and "
                            "mock prediction scripts are hand-authored JSON. Synthetic Gate A data: validates harness "
                            "infrastructure and scorers, never recognition quality.",
        "items": items,
    }
    files[MANIFESTS / "synthetic.json"] = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode()
    return files


# -------------------------------------------------------------------- write --

def build_outputs() -> dict[str, bytes]:
    valid = valid_fixtures()
    malformed = malformed_fixtures()
    files: dict[str, bytes] = {}
    entries = []
    for name, f in sorted(valid.items()):
        rel = f"audio/{name}.wav"
        files[rel] = f["bytes"]
        entries.append({"name": name, "path": rel, "sha256": hashlib.sha256(f["bytes"]).hexdigest(),
                        "byte_count": len(f["bytes"]), **{k: v for k, v in f.items() if k != "bytes"}})
    bad = []
    for name, f in sorted(malformed.items()):
        rel = f"audio/malformed/{name}.wav"
        files[rel] = f["bytes"]
        bad.append({"name": name, "path": rel, "sha256": hashlib.sha256(f["bytes"]).hexdigest(),
                    "byte_count": len(f["bytes"]), "expected_error": f["expected_error"], "purpose": f["purpose"]})
    manifest = {"generator": "scripts/generate_fixtures.py", "generator_version": GENERATOR_VERSION,
                "note": "Synthetic infrastructure fixtures; not speech. Project-generated.",
                "valid": entries, "malformed": bad}
    files["audio/fixtures.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return files


def goldens_bytes() -> bytes:
    return (json.dumps(goldens(valid_fixtures()), indent=2) + "\n").encode()


def long_fixture(seconds: int) -> dict[str, bytes]:
    """P01/P02/P03 input: 16 kHz mono PCM16 tone, generated locally (never committed),
    plus generated references and a mock script (one utterance and one speaker turn
    per 10 s block). Accuracy on these items is not a characterization goal."""
    frames = seconds * TARGET_RATE
    data = bytearray()
    for n in range(frames):
        data += quantize(0.3 * math.sin(2.0 * math.pi * 440 * n / TARGET_RATE), 16).to_bytes(2, "little", signed=True)
    item = f"long-{seconds}s"
    block = 10 * TARGET_RATE
    starts = list(range(0, frames, block))
    header = {"schema_version": "1.0", "source_id": item, "languages": ["en"],
              "timebase": {"unit": "samples", "sample_rate_hz": TARGET_RATE}, "duration_samples": frames,
              "original_precision": {"unit": "samples", "step": 1},
              "coverage": [{"start_sample": 0, "end_sample": frames}]}
    transcript = {**header, "kind": "transcript", "granularity": "utterances",
                  "segments": [{"segment_id": f"u{i}", "start_sample": s, "end_sample": min(s + block, frames),
                                "text": f"block {i}"} for i, s in enumerate(starts)], "recording_text": None}
    speakers = {**header, "kind": "speakers",
                "segments": [{"segment_id": f"r{i}", "speaker_id": "AB"[i % 2], "start_sample": s,
                              "end_sample": min(s + block, frames)} for i, s in enumerate(starts)]}
    script = {"schema_version": "1.0", "kind": "mock_fixture_script", "source_id": item, "sample_rate_hz": TARGET_RATE,
              "duration_samples": frames, "perturbation": None, "faults": [],
              "asr": [{"ordinal": i, "trigger_sample": min(s + block, frames), "utterance_id": f"u{i}", "revision": 0,
                       "text": f"block {i}", "is_final": True, "start_sample": s, "end_sample": min(s + block, frames)}
                      for i, s in enumerate(starts)],
              "diarization": [{"ordinal": i, "trigger_sample": min(s + block, frames), "segment_id": f"h{i}",
                               "speaker_id": "XY"[i % 2], "start_sample": s, "end_sample": min(s + block, frames)}
                              for i, s in enumerate(starts)]}
    encode = lambda value: (json.dumps(value, indent=2) + "\n").encode()
    return {f"long_{seconds}s_16k_pcm16.wav": riff(fmt_chunk(PCM, 1, TARGET_RATE, 16), chunk(b"data", bytes(data))),
            f"{item}.transcript.json": encode(transcript), f"{item}.speakers.json": encode(speakers),
            f"{item}.script.json": encode(script)}


def long_manifest(out: Path, files: dict[str, bytes], lengths: list[int]) -> bytes:
    sha = lambda name: hashlib.sha256(files[name]).hexdigest()
    items = []
    for seconds in lengths:
        item = f"long-{seconds}s"
        t, s = sha(f"{item}.transcript.json"), sha(f"{item}.speakers.json")
        items.append({"item_id": item, "languages": ["en"], "split": "characterization", "status": "ready",
                      "audio_path": f"long_{seconds}s_16k_pcm16.wav", "audio_sha256": sha(f"long_{seconds}s_16k_pcm16.wav"),
                      "sample_rate_hz": TARGET_RATE, "channels": 1, "duration_samples": seconds * TARGET_RATE,
                      "reference_text_path": f"{item}.transcript.json", "reference_text_sha256": t,
                      "speaker_segments_path": f"{item}.speakers.json", "speaker_segments_sha256": s,
                      "reference_sha256": hashlib.sha256(f"{t}\n{s}\n".encode()).hexdigest(),
                      "fixture_script_path": f"{item}.script.json", "fixture_script_sha256": sha(f"{item}.script.json"),
                      "annotation_type": "mixed", "coverage": {"transcript": True, "speakers": True, "joint_words": False},
                      "rights_notes": SYNTHETIC_RIGHTS + " Generated locally for M7 timing characterization; not committed."})
    return (json.dumps({"schema_version": "1.0", "dataset_id": "phase0-synthetic-long", "version": "1", "languages": ["en"],
                        "source_name": "project_generated", "source_url": None,
                        "license": "MIT (project-authored synthetic data; see LICENSE)",
                        "license_verified": True, "redistribution_allowed": True, "external_root": None,
                        "annotation_type": "mixed", "status": "ready",
                        "provenance_notes": "Generated by scripts/generate_fixtures.py --long-seconds (" + GENERATOR_VERSION + ").",
                        "items": items}, indent=2) + "\n").encode()


def write(files: dict[str, bytes], out: Path) -> None:
    for rel, payload in files.items():
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--small", action="store_true", help="the committed small fixture set (+ count goldens)")
    parser.add_argument("--long-seconds", type=int, action="append",
                        help="write a long characterization item of this length (repeatable) and its manifest")
    parser.add_argument("--verify", action="store_true",
                        help="regenerate in memory and compare byte-for-byte with the files on disk")
    args = parser.parse_args()
    out = Path(args.out) if Path(args.out).is_absolute() else ROOT / args.out
    planned: dict[Path, bytes] = {}
    if args.small:
        planned.update({out / rel: payload for rel, payload in build_outputs().items()})
        planned[GOLDENS] = goldens_bytes()
        planned.update(synthetic_outputs(out))
    if args.long_seconds:
        files: dict[str, bytes] = {}
        for seconds in args.long_seconds:
            files.update(long_fixture(seconds))
        files["manifest.json"] = long_manifest(out, files, args.long_seconds)
        planned.update({out / rel: payload for rel, payload in files.items()})
    if not planned:
        parser.error("choose --small and/or --long-seconds")

    if not args.verify:
        for path, payload in planned.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        print(f"wrote {len(planned)} files")
        return 0

    mismatches = []
    for path, payload in sorted(planned.items()):
        if not path.is_file():
            mismatches.append(f"missing: {path.relative_to(ROOT)}")
        elif path.read_bytes() != payload:
            mismatches.append(f"differs: {path.relative_to(ROOT)}")
    for line in mismatches:
        print(line, file=sys.stderr)
    print(f"verify: {len(planned)} files regenerated, {len(mismatches)} mismatches")
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
