"""Schema corpus, strict loading and Swift<->Python parity (V13)."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

import pytest
import referencing.exceptions

from phase0_analysis.schemas import (
    SWIFT_KINDS, TARGETS, SchemaStore, StrictJSONError, canonical_bytes, check_corpus, load_strict, loads_strict,
)


@pytest.fixture(scope="module")
def store(project_root: Path) -> SchemaStore:
    return SchemaStore(project_root / "schemas/v1")


def test_every_documented_schema_exists(store: SchemaStore) -> None:
    expected = {"common", "config", "dataset", "annotations", "event", "predictions", "metrics", "telemetry",
                "environment", "runtime-summary", "status", "validation", "comparison", "fixture-script"}
    assert {name.removesuffix(".schema.json") for name in store.schemas} == expected


def test_refs_resolve_offline_and_unknown_refs_fail(store: SchemaStore) -> None:
    assert store.check_offline_refs() == []
    resolver = store.registry.resolver()
    with pytest.raises(referencing.exceptions.Unresolvable):
        resolver.lookup("https://json-schema.org/draft/2020-12/schema")  # never fetched


def test_corpus(store: SchemaStore, project_root: Path) -> None:
    report = check_corpus(store, project_root / "testdata/schemas")
    assert report["failures"] == [], json.dumps(report["failures"], indent=2, ensure_ascii=False)
    assert report["targets_without_valid_example"] == []
    assert report["total"] >= 90


@pytest.mark.parametrize("text", [
    '{"a": 1, "a": 2}', '{"a": NaN}', '{"a": Infinity}', '{"a": -Infinity}', '"\\ud800"', '{"a": 1e400}',
])
def test_strict_loader_rejects(text: str) -> None:
    with pytest.raises(StrictJSONError):
        loads_strict(text)


def test_strict_loader_rejects_invalid_utf8() -> None:
    with pytest.raises(StrictJSONError):
        loads_strict(b'"\xff"')


def test_integer_type_excludes_floats_and_booleans(store: SchemaStore) -> None:
    record = load_strict(Path(__file__).resolve().parents[2] / "testdata/schemas/valid/metric-record/ok-ratio.json")
    assert store.issues("metric-record", record) == []
    for bad in (3.0, True):
        assert store.issues("metric-record", dict(record, sample_count=bad))


def test_pending_manifests_validate(store: SchemaStore, project_root: Path) -> None:
    for name in ("english-pending", "hindi-pending"):
        manifest = load_strict(project_root / f"datasets/manifests/{name}.json")
        assert store.issues("dataset", manifest) == []
        assert manifest["status"] == "pending" and manifest["items"] == []


# ---- cross-language parity: Swift writes, Python validates (and vice versa) ----

def _swift(voicebench: Path, *args: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run([str(voicebench), "dev", *args], capture_output=True, timeout=60, check=False)


def _swift_cases(project_root: Path, group: str) -> list[tuple[str, Path]]:
    cases = []
    for target in sorted(SWIFT_KINDS):
        for path in sorted((project_root / "testdata/schemas" / group / target).glob("*.json")):
            cases.append((target, path))
    return cases


ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("target,path", _swift_cases(ROOT, "valid"), ids=lambda v: getattr(v, "name", v))
def test_swift_reencode_validates_in_python(target: str, path: Path, voicebench: Path, store: SchemaStore,
                                            tmp_path: Path) -> None:
    out = tmp_path / "out.json"
    result = _swift(voicebench, "roundtrip", "--kind", SWIFT_KINDS[target], "--input", str(path), "--output", str(out))
    assert result.returncode == 0, result.stderr.decode()
    reencoded = load_strict(out)
    assert store.issues(target, reencoded) == []
    assert reencoded == load_strict(path), "Swift re-encode changed document content"


@pytest.mark.parametrize("target,path", _swift_cases(ROOT, "invalid") + _swift_cases(ROOT, "semantic-invalid"),
                         ids=lambda v: getattr(v, "name", v))
def test_swift_rejects_invalid(target: str, path: Path, voicebench: Path, tmp_path: Path) -> None:
    result = _swift(voicebench, "roundtrip", "--kind", SWIFT_KINDS[target], "--input", str(path),
                    "--output", str(tmp_path / "out.json"))
    assert result.returncode != 0, f"Swift accepted {path}"
    assert result.stderr, "rejection must carry an actionable message"


CANONICAL_CORPUS = {
    "hindi": "हिन्दी नमस्ते", "emoji": "🙂👍🏽", "solidus": "a/b\\c", "quote": 'say "hi"',
    "controls": "\u0000\u0001\b\t\n\f\r\u001f\u007f", "separators": "  ", "nfd": "क़",
    "nested": {"z": [1, -2, 0, 9223372036854775807, -9223372036854775808], "a": None, "é": True, "Z": False},
}


def test_canonical_bytes_match_swift(voicebench: Path, tmp_path: Path) -> None:
    source = tmp_path / "in.json"
    source.write_text(json.dumps(CANONICAL_CORPUS, indent=1, ensure_ascii=True), encoding="utf-8")
    result = _swift(voicebench, "canonical", "--input", str(source))
    assert result.returncode == 0, result.stderr.decode()
    assert result.stdout == canonical_bytes(CANONICAL_CORPUS)


def test_config_settings_hash_parity(voicebench: Path, store: SchemaStore, project_root: Path) -> None:
    result = _swift(voicebench, "config-settings", "--config", str(project_root / "configs/mock-step.yaml"))
    assert result.returncode == 0, result.stderr.decode()
    body, _, digest_line = result.stdout.rpartition(b"\n")[0].rpartition(b"\n")
    settings = loads_strict(body)
    assert store.issues("config-settings", settings) == []
    assert hashlib.sha256(body).hexdigest() == digest_line.decode()
    # Python re-encoding of the persisted bytes reproduces them exactly.
    assert canonical_bytes(settings) == body


def test_config_overrides_change_settings_hash(voicebench: Path, project_root: Path) -> None:
    config = str(project_root / "configs/mock-step.yaml")
    base = _swift(voicebench, "config-settings", "--config", config).stdout.split(b"\n")[-2]
    accel = _swift(voicebench, "config-settings", "--config", config, "--mode", "accelerated", "--speed", "4")
    assert accel.returncode == 0, accel.stderr.decode()
    assert accel.stdout.split(b"\n")[-2] != base
    assert b'"speed":{"den":1,"num":4}' in accel.stdout
    bad = _swift(voicebench, "config-settings", "--config", config, "--frame-ms", "30")
    assert bad.returncode != 0 and b"frame_ms" in bad.stderr


def test_targets_cover_all_schema_files(store: SchemaStore) -> None:
    referenced = {uri.split("#")[0] for uri in TARGETS.values()}
    assert referenced == set(store.schemas)


PREPARE_CASES = ["mono48k_f32_tone1k", "mono44k1_f32_len7", "mono22k05_f32_len2", "mono16k_pcm16_empty",
                 "mono16k_pcm16_tone440_1s", "stereo48k_pcm24_tone1k"]


@pytest.mark.parametrize("fixture", PREPARE_CASES)
def test_swift_conversion_record_validates(fixture: str, voicebench: Path, store: SchemaStore, project_root: Path,
                                           tmp_path: Path) -> None:
    wav = project_root / "datasets/fixtures/audio" / f"{fixture}.wav"
    result = subprocess.run([str(voicebench), "dev", "prepare-audio", "--input", str(wav), "--scratch",
                             str(tmp_path / "scratch")], capture_output=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr.decode()
    report = loads_strict(result.stdout)
    conversion = report["conversion"]
    assert store.issues("runtime-summary-conversion", conversion) == []
    golden = load_strict(project_root / "testdata/goldens/audio-counts.json")["fixtures"][fixture]
    assert conversion["intended_frames"] == golden["converted_frames"] == report["spool"]["frame_count"]
    corrected = conversion["native_frames"] != conversion["intended_frames"]
    assert (conversion["endpoint_status"] in ("trimmed_one_frame", "zero_extended_one_frame")) == corrected
    spool = tmp_path / "scratch" / "converted.f32le"
    assert hashlib.sha256(spool.read_bytes()).hexdigest() == report["spool"]["sha256"] == conversion["converted_sha256"]


def test_strict_endpoint_policy_refuses_a_corrected_conversion(voicebench: Path, project_root: Path,
                                                               tmp_path: Path) -> None:
    """Find a fixture whose lenient conversion needed a correction, then require strict mode to fail on it."""
    corrected = None
    for fixture in PREPARE_CASES:
        wav = project_root / "datasets/fixtures/audio" / f"{fixture}.wav"
        lenient = subprocess.run([str(voicebench), "dev", "prepare-audio", "--input", str(wav), "--scratch",
                                  str(tmp_path / f"lenient-{fixture}")], capture_output=True, timeout=60, check=True)
        if loads_strict(lenient.stdout)["conversion"]["endpoint_status"] not in ("exact", "bypassed"):
            corrected = wav
            break
    assert corrected is not None, "no fixture needed a correction; the strict path was not exercised"
    strict = subprocess.run([str(voicebench), "dev", "prepare-audio", "--input", str(corrected), "--strict",
                             "--scratch", str(tmp_path / "strict")], capture_output=True, timeout=60, check=False)
    assert strict.returncode != 0
    assert b"conversionContract" in strict.stderr


def test_schema_bundle_is_frozen(project_root: Path) -> None:
    """DEC-008: schema 1.0 was frozen before the first sealed benchmark run. Any schema
    edit changes this digest and must come with a new schema version."""
    from phase0_analysis.validate import schema_bundle_digest

    recorded = (project_root / "schemas/SCHEMA_BUNDLE_V1.sha256").read_text().split()[0]
    assert schema_bundle_digest(project_root / "schemas/v1") == recorded
