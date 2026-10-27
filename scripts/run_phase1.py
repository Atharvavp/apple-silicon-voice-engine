#!/usr/bin/env python3
"""Phase 1 campaign orchestration (one-shot plan, stages 1 and 5).

Subcommands (all outputs go to a NEW directory; nothing is ever overwritten or deleted):

  snapshot   record git state and the digests of protected inputs/evidence
  verify     compare the current tree against a snapshot (protected files unchanged)
  campaign   preflight, smokes, frozen matrix, repeated fresh-process runs and per-run validation
  vendor-speech  create the owned speech-swift copy at the pinned SHA plus the two-file patch
  verify-speech  check an existing owned copy read-only (pinned HEAD, diff == patch bytes, files)

    .venv/bin/python scripts/run_phase1.py snapshot --out "$SESSION/snapshot-start.json"
    .venv/bin/python scripts/run_phase1.py verify --snapshot "$SESSION/snapshot-start.json" --out "$SESSION/snapshot-end.json"
    .venv/bin/python scripts/run_phase1.py campaign --inputs "$INPUTS" --datasets "$SESSION/datasets" \
        --voicebench .build/phase1-both/release/voicebench --out "$SESSION/campaign"

The campaign never downloads anything: model assets and datasets must already exist under the
roots named in the owner-provided inputs file (acquisition, when the owner authorizes it, is a
separate setup step). A configuration whose prerequisites are missing is recorded as blocked with
its reason; independent configurations continue. Every real run executes under a deny-network
sandbox, so a run can only load the verified local files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Files whose bytes Phase 1 must not change: frozen schemas, scoring/normalization, harness
# contracts and runner, historical evidence and the Phase 0 report.
PROTECTED_GLOBS = [
    "schemas/**/*",
    "analysis/src/phase0_analysis/*.py",
    "Sources/AdapterContracts/*.swift",
    "Sources/Experiment/*.swift",
    "Sources/BenchmarkSupport/*.swift",
    "Sources/AudioCore/*.swift",
    "Sources/Replay/*.swift",
    "Sources/Telemetry/*.swift",
    "Sources/CTelemetry/**/*",
    "Sources/MockAdapters/*.swift",
    "configs/*.yaml",
    "datasets/**/*",
    "testdata/**/*",
    "PHASE_0_READINESS_REPORT.md",
]
EVIDENCE_DIRS = ["evidence/M1", "evidence/M2", "evidence/M2-hardening", "evidence/M3", "evidence/M4",
                 "evidence/M5", "evidence/M6", "evidence/M7"]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def schema_bundle_digest() -> tuple[str, int]:
    """Same preimage as Swift `SchemaBundle.compute`: sorted '<name> <sha256>\\n' lines."""
    names = sorted(p.name for p in (ROOT / "schemas/v1").iterdir() if p.name.endswith(".schema.json"))
    text = "".join(f"{name} {sha256_file(ROOT / 'schemas/v1' / name)}\n" for name in names)
    return hashlib.sha256(text.encode()).hexdigest(), len(names)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout


def file_table(paths: list[Path]) -> dict[str, str]:
    return {str(p.relative_to(ROOT)): sha256_file(p) for p in sorted(paths) if p.is_file() and not p.is_symlink()}


def tree_digest(table: dict[str, str]) -> str:
    return hashlib.sha256("".join(f"{k} {v}\n" for k, v in sorted(table.items())).encode()).hexdigest()


def take_snapshot() -> dict:
    protected: list[Path] = []
    for pattern in PROTECTED_GLOBS:
        protected.extend(p for p in ROOT.glob(pattern) if "__pycache__" not in p.parts)
    protected_table = file_table(protected)
    evidence: dict[str, dict] = {}
    for rel in EVIDENCE_DIRS:
        directory = ROOT / rel
        table = file_table([p for p in directory.rglob("*")]) if directory.is_dir() else {}
        evidence[rel] = {"files": len(table), "digest": tree_digest(table), "table": table}
    bundle, count = schema_bundle_digest()
    recorded = (ROOT / "schemas/SCHEMA_BUNDLE_V1.sha256").read_text().split()[0]
    return {
        "snapshot_version": 1,
        "git": {"head": git("rev-parse", "HEAD").strip(), "branch": git("rev-parse", "--abbrev-ref", "HEAD").strip(),
                "porcelain": git("status", "--porcelain=v1").splitlines()},
        "schema_bundle": {"sha256": bundle, "file_count": count, "recorded_freeze": recorded,
                          "frozen": bundle == recorded},
        "protected": {"files": len(protected_table), "digest": tree_digest(protected_table), "table": protected_table},
        "evidence": evidence,
        "host": {"platform": platform.platform(), "python": sys.version.split()[0]},
    }


def write_new(path: Path, payload: dict) -> None:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as handle:  # refuses an existing file
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def compare_snapshots(before: dict, after: dict) -> dict:
    problems: list[str] = []
    if after["schema_bundle"]["sha256"] != before["schema_bundle"]["sha256"]:
        problems.append("schema bundle digest changed")
    if not after["schema_bundle"]["frozen"]:
        problems.append("schema bundle no longer matches the frozen record")
    old, new = before["protected"]["table"], after["protected"]["table"]
    for name in sorted(set(old) | set(new)):
        if old.get(name) != new.get(name):
            state = "removed" if name not in new else "added" if name not in old else "modified"
            problems.append(f"protected file {state}: {name}")
    for rel, record in before["evidence"].items():
        now = after["evidence"].get(rel, {})
        if now.get("digest") != record["digest"]:
            changed = sorted(k for k in set(record["table"]) | set(now.get("table", {}))
                             if record["table"].get(k) != now.get("table", {}).get(k))
            problems.append(f"historical evidence changed in {rel}: {changed[:10]}")
    return {"status": "pass" if not problems else "fail", "problems": problems,
            "head_before": before["git"]["head"], "head_after": after["git"]["head"]}


# --- owned speech-swift copy ------------------------------------------------------------------

SPEECH_VENDOR = ROOT / "vendor/speech-swift"
SPEECH_PATCH = ROOT / "patches/speech-swift-3f58a58a-phase1.patch"
SPEECH_PATCHED_FILES = ["Package.swift", "Sources/ParakeetStreamingASR/ParakeetStreamingASR.swift"]


def vendor_speech(dest: Path) -> dict:
    """The owned copy is the exact pinned commit plus one patch touching two files:
    * Package.swift renames speech-swift's benchmark-only `BenchmarkSupport` target, which collides
      with the harness module (SwiftPM requires unique target names; module aliases cannot reach it);
    * ParakeetStreamingASR.swift adds optional `cacheDir:`/`offlineMode:` loader parameters (defaults
      keep upstream behavior), so the verified cache loads without ~110 s of Hub retries.
    No inference, preprocessing or decoding code changes."""
    if dest.exists():
        raise FileExistsError(f"{dest} exists; verify it with `git -C {dest} diff` instead of recreating it")
    dest.parent.mkdir(parents=True, exist_ok=True)
    def git_in(*args: str) -> str:
        return subprocess.run(["git", "-C", str(dest), *args], capture_output=True, text=True, check=True).stdout
    subprocess.run(["git", "init", "-q", str(dest)], check=True)
    git_in("fetch", "-q", "--depth", "1", "https://github.com/soniqo/speech-swift.git", SPEECH_REVISION)
    git_in("checkout", "-q", "FETCH_HEAD")
    head = git_in("rev-parse", "HEAD").strip()
    if head != SPEECH_REVISION:
        raise RuntimeError(f"fetched {head}, expected {SPEECH_REVISION}")
    git_in("apply", str(SPEECH_PATCH))
    changed = git_in("diff", "--name-only").split()
    if changed != SPEECH_PATCHED_FILES:
        raise RuntimeError(f"patch changed {changed}; only {SPEECH_PATCHED_FILES} may change")
    record = {"source": "https://github.com/soniqo/speech-swift.git", "revision": head,
              "patch": str(SPEECH_PATCH.relative_to(ROOT)), "patch_sha256": sha256_file(SPEECH_PATCH),
              "changed_files": changed, "patched_manifest_sha256": sha256_file(dest / "Package.swift"),
              "patched_files_sha256": {name: sha256_file(dest / name) for name in changed},
              "license_sha256": sha256_file(dest / "LICENSE")}
    (dest / "PHASE1_VENDOR.json").write_text(json.dumps(record, indent=2) + "\n")
    return record


def verify_speech(dest: Path, revision: str | None = None, patch: Path | None = None) -> dict:
    """Read-only identity check of an existing owned copy; `Package.resolved` cannot pin a path
    dependency, so this is the authentication of the speech-swift source. Nothing is written to `dest`.
    Passes only if HEAD is the pinned commit, the working-tree diff is byte-identical to the owned
    patch, exactly the two patched files differ and no other untracked file exists (the copy's own
    PHASE1_VENDOR.json record is reported, not trusted: older records name an obsolete patch)."""
    revision = revision or SPEECH_REVISION
    patch = patch or SPEECH_PATCH
    problems: list[str] = []
    def git_in(*args: str) -> bytes:
        return subprocess.run(["git", "-C", str(dest), *args], capture_output=True, check=True).stdout
    if not (dest / ".git").exists():
        return {"status": "fail", "dest": str(dest), "problems": [f"{dest} is not a git checkout"]}
    head = git_in("rev-parse", "HEAD").decode().strip()
    if head != revision:
        problems.append(f"HEAD {head} is not the pinned {revision}")
    diff = git_in("diff", "--no-color", "--no-ext-diff")
    if diff != patch.read_bytes():
        problems.append("working-tree diff differs from the owned patch bytes")
    changed = git_in("diff", "--name-only").decode().split()
    if changed != SPEECH_PATCHED_FILES:
        problems.append(f"changed files {changed}, expected {SPEECH_PATCHED_FILES}")
    untracked = [name for name in git_in("ls-files", "--others", "--exclude-standard").decode().split()
                 if name != "PHASE1_VENDOR.json"]
    if untracked:
        problems.append(f"unexpected untracked files: {untracked[:10]}")
    record_path = dest / "PHASE1_VENDOR.json"
    recorded = json.loads(record_path.read_text()) if record_path.is_file() else None
    patch_sha = sha256_file(patch)
    return {"status": "pass" if not problems else "fail", "problems": problems, "dest": str(dest),
            "revision": head, "expected_revision": revision, "patch": str(patch.name), "patch_sha256": patch_sha,
            "diff_sha256": sha256_bytes(diff), "changed_files": changed,
            "patched_files_sha256": {name: sha256_file(dest / name) for name in changed if (dest / name).is_file()},
            "license_sha256": sha256_file(dest / "LICENSE") if (dest / "LICENSE").is_file() else None,
            "recorded_vendor_record": recorded,
            "recorded_vendor_record_matches_patch": bool(recorded) and recorded.get("patch_sha256") == patch_sha}


# --- campaign -------------------------------------------------------------------------------

FLUID_REVISION = "61d41b3ca04833d1cb80632c82ba401f117a01ef"
SPEECH_REVISION = "3f58a58a8f867a4c87b97dbf4d6050d6a88ef665"
FRAMEWORKS = {
    "fluid": {"name": "FluidAudio", "source": "https://github.com/FluidInference/FluidAudio", "revision": FLUID_REVISION,
              "version_token": "FluidAudio@" + FLUID_REVISION[:12]},
    "speech": {"name": "speech-swift", "source": "https://github.com/soniqo/speech-swift", "revision": SPEECH_REVISION,
               "version_token": "speech-swift@" + SPEECH_REVISION[:12]},
}
PASSIVE = {"asr": ("passive-asr", "passive-v1"), "diarization": ("passive-diar", "passive-v1")}
TAIL_TOLERANCE = 2 * 1280  # two 80 ms Sortformer frames of declared end-of-stream padding

# The frozen benchmark matrix (one-shot plan section 2). Settings mirror what each Swift wrapper
# verifies; a mismatch fails prepare instead of silently loading something else.
MATRIX = [
    {"row": "D1", "role": "diarization", "framework": "fluid", "adapter_id": "fluid-sortformer-v21-lowctx",
     "projection": "final_timeline_at_flush",
     "settings": {"preset": "fastV2_1", "precision": "fp16", "chunk_len": 6, "left_context": 1, "right_context": 7,
                  "fifo_len": 40, "spkcache_len": 188, "spkcache_update_period": 31, "num_speakers": 4,
                  "subsampling_factor": 8, "mel_stride": 160, "sample_rate": 16000, "onset_threshold": 0.5,
                  "offset_threshold": 0.5, "onset_pad_frames": 0, "offset_pad_frames": 0, "min_frames_on": 0,
                  "min_frames_off": 0}},
    {"row": "D2", "role": "diarization", "framework": "speech", "adapter_id": "speech-sortformer-v21-streaming",
     "projection": "final_timeline_at_flush",
     "settings": {"preset": "streaming", "model_file": "Sortformer_streaming.mlmodelc", "chunk_len": 6,
                  "left_context": 1, "right_context": 7, "fifo_len": 40, "spkcache_len": 188,
                  "spkcache_update_period": 32, "num_speakers": 4, "subsampling_factor": 8, "mel_stride": 160,
                  "sample_rate": 16000, "onset_threshold": 0.5, "offset_threshold": 0.5, "min_speech_s": 0.3,
                  "min_silence_s": 0.15}},
    {"row": "A1", "role": "asr", "framework": "fluid", "adapter_id": "fluid-parakeet-eou-120m-320ms",
     "projection": "recording_text_cumulative_partials_one_final",
     "settings": {"chunk_size": "320ms", "chunk_samples": 10080, "shift_samples": 5120, "mel_frames": 64,
                  "pre_cache_size": 9, "eou_debounce_ms": 1280, "decoder_path": "reference_two_model"}},
    {"row": "A2", "role": "asr", "framework": "speech", "adapter_id": "speech-parakeet-eou-120m-int8",
     "projection": "recording_text_segment_assembly_one_final",
     "settings": {"chunk_ms": 320, "mel_frames": 64, "pre_cache_size": 9, "output_frames": 4, "sample_rate": 16000,
                  "eou_debounce_ms": 1280}},
]
SANDBOX = "/usr/bin/sandbox-exec"
DENY_NETWORK = "(version 1)(allow default)(deny network*)"
RSS_WARN = 8 << 30
RSS_STOP = 10 << 30


def add_campaign_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--inputs", required=True, help="absolute path of the owner's phase1-inputs.json")
    parser.add_argument("--datasets", required=True, help="output directory of prepare_phase1_data.py")
    parser.add_argument("--voicebench", required=True, help="release binary used for every framework present in it")
    parser.add_argument("--binary", action="append", default=[], metavar="FRAMEWORK=PATH",
                        help="per-framework binary override when a joint build was not possible")
    parser.add_argument("--out", required=True, help="new campaign directory (refused if it exists)")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--cooldown-s", type=int, default=60)
    parser.add_argument("--skip-measured", action="store_true", help="preflight, profiles and smokes only")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class Ledger:
    """Append-only JSONL record of every attempt (failures included); never rewritten."""

    def __init__(self, path: Path):
        self.path = path

    def append(self, entry: dict) -> None:
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")


def is_full_revision(text: object) -> bool:
    return isinstance(text, str) and len(text) == 40 and all(c in "0123456789abcdef" for c in text)


def model_prerequisites(row: dict, inputs: dict) -> tuple[dict | None, str | None]:
    """The owner-supplied model entry for a row, or the reason it is blocked."""
    entry = (inputs.get("models") or {}).get(row["adapter_id"])
    if not entry:
        return None, f"inputs supply no model entry for {row['adapter_id']}"
    acceptance = entry.get("license_acceptance") or {}
    if acceptance.get("accepted") is not True or not acceptance.get("evidence"):
        return None, "no recorded owner acceptance of the original NVIDIA and conversion terms"
    if not is_full_revision(entry.get("revision")):
        return None, "model revision is not a full immutable 40-character commit SHA"
    for key in ("root", "repository", "load_path", "precision", "licenses"):
        if not entry.get(key):
            return None, f"model entry lacks {key}"
    root = Path(entry["root"])
    if not root.is_absolute() or not (root / entry["load_path"]).exists():
        return None, f"local model files are absent at {root / entry['load_path']} (acquisition not performed)"
    return entry, None


def build_profile(row: dict, entry: dict, lock_sha: str | None) -> bytes:
    """Profile bytes: every regular file under the load path, hashed now (selection is local only)."""
    root = Path(entry["root"])
    load = root / entry["load_path"]
    paths = [load] if load.is_file() else sorted(p for p in load.rglob("*") if p.is_file() and not p.is_symlink())
    extra = [root / rel for rel in entry.get("extra_files", [])]
    files = []
    for path in paths + extra:
        files.append({"path": str(path.relative_to(root)), "sha256": sha256_file(path), "bytes": path.stat().st_size})
    framework = FRAMEWORKS[row["framework"]]
    profile = {
        "profile_version": 1, "adapter_id": row["adapter_id"], "role": row["role"],
        "framework": {"name": framework["name"], "source": framework["source"], "revision": framework["revision"],
                      "dependency_lock_sha256": lock_sha},
        "model": {"repository": entry["repository"], "revision": entry["revision"], "licenses": entry["licenses"],
                  "precision": entry["precision"], "load_path": entry["load_path"], "files": files},
        "compute_units": "all",
        "settings": row["settings"],
        "output": {"projection": row["projection"],
                   "eos_tail_tolerance_samples": TAIL_TOLERANCE if row["role"] == "diarization" else None},
        "notes": entry.get("notes", "") + (" Speaker labels are emitted once at end of stream (final-only); online "
                                           "speaker-label latency is not computable by design."
                                           if row["role"] == "diarization" else
                                           " Recording-granularity text; no word timestamps."),
    }
    return (json.dumps(profile, indent=2, sort_keys=True) + "\n").encode("utf-8")


def config_yaml(row: dict | None, revision: str | None, manifest: Path, item_id: str, *, mode: str = "realtime",
                mock: bool = False) -> str:
    if mock:
        asr, diar = ("mock-asr-scripted", "1"), ("mock-diar-scripted", "1")
        warm = "not_applicable_mock"
    else:
        active = (row["adapter_id"], revision)
        other = "asr" if row["role"] == "diarization" else "diarization"
        asr, diar = (active, PASSIVE[other]) if row["role"] == "asr" else (PASSIVE[other], active)
        warm = "fresh_process_model_loaded_in_prepare_os_model_caches_unknown"
    return f"""# Generated by scripts/run_phase1.py; frozen before measured runs.
schema_version: "1.0"
experiment_name: phase1-{row['row'].lower() if row else 'mock-pacing'}
dataset:
  manifest_path: {manifest}
  item_id: {item_id}
audio:
  target_sample_rate_hz: 16000
  downmix_policy: arithmetic_mean_v1
  conversion_policy: apple_normal_max_half_up_v1
  endpoint_policy: allow_one_frame_v1
replay:
  mode: {mode}
  frame_ms: 20
  speed: null
  queue_capacity: 32
  overflow: block
adapters:
  asr: {{id: {asr[0]}, revision: "{asr[1]}", delay_ms: 0}}
  diarization: {{id: {diar[0]}, revision: "{diar[1]}", delay_ms: 0}}
seed: 42
scoring:
  references: optional
  text_policy: nfc_casefold_punct_space_cp_v1
  diarization_policy: pyannote_c0_overlap_uem_v1
telemetry:
  enabled: true
  interval_ms: 1000
runtime:
  python_executable: {ROOT / '.venv/bin/python'}
  cleanup_timeout_s: 30
  analysis_timeout_s: 900
  max_output_bytes: 1073741824
notes:
  warm_state: {warm}
  background_load: recorded-in-campaign-ledger
"""


def measured_order(repeats: int) -> list[tuple[int, str, list[str]]]:
    """Per repetition and role (diarization first): F/S, S/F, F/S alternation."""
    order = []
    for rep in range(1, repeats + 1):
        frameworks = ["fluid", "speech"] if rep % 2 == 1 else ["speech", "fluid"]
        for role in ("diarization", "asr"):
            order.append((rep, role, frameworks))
    return order


def run_timeout_s(duration_samples: int) -> int:
    """3 x media duration + 10 min, at least 10 min."""
    return max(600, 3 * duration_samples // 16000 + 600)


def host_conditions() -> dict:
    def capture(argv: list[str]) -> str | None:
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=15, check=False).stdout.strip()[:2000]
        except (OSError, subprocess.SubprocessError):
            return None
    return {"wall_time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "power": capture(["pmset", "-g", "batt"]),
            "thermal": capture(["pmset", "-g", "therm"]), "loadavg": os.getloadavg(),
            "memory_pressure_level": memory_pressure_level(),
            "thermal_note": "pmset therm reports OS limits only; 'nominal' does not prove a stable temperature"}


def memory_pressure_level() -> int | None:
    """kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical (unprivileged read)."""
    try:
        out = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True,
                             timeout=5, check=False).stdout.strip()
        return int(out) if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def process_rss(pid: int) -> int | None:
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, timeout=5,
                             check=False).stdout.strip()
        return int(out) * 1024 if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def supervised(argv: list[str], env: dict, timeout_s: int, log: Path, poll_s: float = 2.0) -> dict:
    """Runs one owned process; stops it (SIGINT -> cooperative cancel) on timeout, RSS >= 10 GiB or
    critical memory pressure. Never touches any other process."""
    started = time.monotonic()
    peak, warned, stop_reason = 0, False, None
    with log.open("x") as handle:
        process = subprocess.Popen(argv, env=env, stdout=handle, stderr=subprocess.STDOUT, cwd=ROOT)
        while process.poll() is None:
            time.sleep(poll_s)
            rss = process_rss(process.pid) or 0
            peak = max(peak, rss)
            warned = warned or rss >= RSS_WARN
            if stop_reason is None:
                if time.monotonic() - started > timeout_s:
                    stop_reason = "timeout"
                elif rss >= RSS_STOP:
                    stop_reason = "rss_limit_10GiB"
                elif memory_pressure_level() == 4:
                    stop_reason = "critical_memory_pressure"
                if stop_reason:
                    process.send_signal(signal.SIGINT)
                    stop_deadline = time.monotonic() + 120
            elif time.monotonic() > stop_deadline:
                process.kill()
        code = process.wait()
    return {"exit_code": code, "elapsed_s": round(time.monotonic() - started, 3), "observed_peak_rss_bytes": peak,
            "rss_warning_8GiB": warned, "stopped_by_supervisor": stop_reason}


def sandbox_controls(out: Path) -> dict:
    """Positive/negative controls for the deny-network policy (same method as V19)."""
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(4)
    port = server.getsockname()[1]
    threading.Thread(target=lambda: [server.accept() for _ in range(4)], daemon=True).start()
    probe = ("import socket\n"
             "def attempt(h,p):\n"
             "    try:\n        socket.create_connection((h,p),timeout=3).close(); return 'connected'\n"
             "    except PermissionError as e: return f'denied: {e}'\n"
             "    except OSError as e: return f'oserror: {e}'\n"
             f"print(attempt('127.0.0.1',{port})); print(attempt('1.1.1.1',443))\n")
    plain = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, timeout=30, check=False)
    boxed = subprocess.run([SANDBOX, "-p", DENY_NETWORK, sys.executable, "-c", probe], capture_output=True, text=True,
                           timeout=30, check=False)
    lines = boxed.stdout.splitlines()
    result = {"policy": DENY_NETWORK, "outside_local": (plain.stdout.splitlines() or [plain.stderr])[0],
              "inside_local": lines[0] if lines else None, "inside_outbound": lines[1] if len(lines) > 1 else None,
              "sandbox_exit_code": boxed.returncode, "sandbox_stderr": boxed.stderr[-300:]}
    result["denial_enforced"] = (result["outside_local"] == "connected" and boxed.returncode == 0 and len(lines) >= 2
                                 and all(line.startswith("denied") for line in lines[:2]))
    write_new(out, result)
    return result


def binary_frameworks(binary: Path) -> tuple[str, list[str]]:
    version = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=30,
                             check=False).stdout.strip()
    present = [name for name, info in FRAMEWORKS.items() if info["version_token"] in version]
    return version, present


def run_env(row: dict | None, profiles: Path, entry: dict | None) -> dict:
    env = {k: v for k, v in os.environ.items() if k not in ("FLUID_EOU_FUSED", "QWEN3_CACHE_DIR", "QWEN3_ASR_CACHE_DIR")}
    env["SPEECH_COREML_COMPUTE_UNITS"] = "all"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if row is not None and entry is not None:
        env["VOICEBENCH_PHASE1_PROFILES"] = str(profiles)
        env["VOICEBENCH_PHASE1_ASSETS"] = str(entry["root"])
    return env


def run_campaign(args: argparse.Namespace) -> int:
    inputs_path = Path(args.inputs)
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    for sub in ("profiles", "configs", "runs", "logs"):
        (out / sub).mkdir()
    ledger = Ledger(out / "ledger.jsonl")
    blocked: dict[str, str] = {}
    summary: dict = {"command": " ".join(sys.argv), "rows": {}, "started": time.strftime("%Y-%m-%dT%H:%M:%S%z")}

    def finish(code: int) -> int:
        summary["blocked"] = blocked
        summary["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        write_new(out / "campaign-summary.json", summary)
        print(json.dumps({"rows": summary["rows"], "blocked": blocked}, indent=2))
        return code

    # Preflight: inputs, binaries, datasets, sandbox.
    if not inputs_path.is_absolute() or not inputs_path.is_file():
        for row in MATRIX:
            blocked[row["row"]] = f"owner inputs file {inputs_path} is missing; no model/data permission or roots"
        summary["status"] = "NOT_RUN"
        return finish(3)
    inputs = json.loads(inputs_path.read_text())
    summary["inputs_sha256"] = sha256_file(inputs_path)
    binaries = {"fluid": Path(args.voicebench).resolve(), "speech": Path(args.voicebench).resolve()}
    for item in args.binary:
        name, _, path = item.partition("=")
        binaries[name] = Path(path).resolve()
    summary["binaries"] = {}
    for name, binary in binaries.items():
        version, present = binary_frameworks(binary) if binary.is_file() else ("", [])
        summary["binaries"][name] = {"path": str(binary), "sha256": sha256_file(binary) if binary.is_file() else None,
                                     "version": version, "frameworks": present}
    lock = ROOT / "Package.resolved"
    lock_sha = sha256_file(lock)
    summary["package_resolved_sha256"] = lock_sha
    freeze_path = Path(args.datasets) / "dataset-freeze.json"
    freeze = json.loads(freeze_path.read_text()) if freeze_path.is_file() else {"datasets": {}}
    ami = freeze["datasets"].get("ami", {})
    summary["dataset_freeze_sha256"] = sha256_file(freeze_path) if freeze_path.is_file() else None
    controls = sandbox_controls(out / "sandbox-controls.json")
    summary["sandbox_denial_enforced"] = controls["denial_enforced"]

    # Setup: profiles per row (local verification only; nothing downloaded here).
    eligible: dict[str, dict] = {}
    for row in MATRIX:
        reasons = []
        if row["framework"] not in summary["binaries"][row["framework"]]["frameworks"]:
            reasons.append(f"{FRAMEWORKS[row['framework']]['name']} is not compiled into {binaries[row['framework']]}")
        if ami.get("status") != "ready":
            reasons.append(f"AMI dataset not ready: {ami.get('reason', 'dataset stage not run')}")
        elif row["role"] not in ami.get("manifests", {}):
            reasons.append(f"no verified {row['role']} reference: {ami.get('asr_reference_blocked')}")
        elif ami["validate_require_ready"][row["role"]]["exit_code"] != 0:
            reasons.append(f"validate --dataset --require-ready failed for the {row['role']} manifest")
        entry, problem = model_prerequisites(row, inputs)
        if problem:
            reasons.append(problem)
        if not controls["denial_enforced"]:
            reasons.append("network-denial sandbox controls failed; offline loading cannot be proven")
        if reasons:
            blocked[row["row"]] = "; ".join(reasons)
            summary["rows"][row["row"]] = "blocked"
            ledger.append({"kind": "setup", "row": row["row"], "status": "blocked", "reasons": reasons})
            continue
        data = build_profile(row, entry, lock_sha)
        (out / "profiles" / f"{row['adapter_id']}.json").write_bytes(data)
        revision = "p1:" + sha256_bytes(data)
        eligible[row["row"]] = {"row": row, "entry": entry, "revision": revision}
        ledger.append({"kind": "setup", "row": row["row"], "status": "profile_frozen", "revision": revision})

    # Smokes (network denied) + missing-cache negative control, per eligible row.
    smoke = freeze["datasets"].get("ami", {}).get("smoke")
    for key, item in list(eligible.items()):
        row = item["row"]
        if smoke is None:
            blocked[key] = "no separate 60 s smoke input (the recording ends at the evaluation crop)"
            summary["rows"][key] = "blocked"
            eligible.pop(key)
            continue
        manifest, item_id = Path(smoke["manifest"]), smoke["item_id"]
        config = out / "configs" / f"{key}-smoke.yaml"
        config.write_text(config_yaml(row, item["revision"], manifest, item_id))
        binary = binaries[row["framework"]]
        for kind, env in (("smoke", run_env(row, out / "profiles", item["entry"])),
                          ("negative_empty_assets", {**run_env(row, out / "profiles", item["entry"]),
                                                     "VOICEBENCH_PHASE1_ASSETS": str(out / "empty-assets")})):
            (out / "empty-assets").mkdir(exist_ok=True)
            run_id = f"{key}-{kind}"
            argv = [SANDBOX, "-p", DENY_NETWORK, str(binary), "run", "--config", str(config), "--runs-dir",
                    str(out / "runs"), "--run-id", run_id]
            result = supervised(argv, env, 600 + 3 * 60, out / "logs" / f"{run_id}.log")
            ok = result["exit_code"] == 0 if kind == "smoke" else result["exit_code"] == 5
            ledger.append({"kind": kind, "row": key, "run_id": run_id, "argv": argv, "network": "denied", **result,
                           "status": "pass" if ok else "fail"})
            if not ok:
                blocked[key] = f"{kind} failed (exit {result['exit_code']}); see logs/{run_id}.log"
        if key in blocked:
            summary["rows"][key] = "blocked"
            eligible.pop(key)

    # Freeze the final matrix before any measured run.
    matrix = {"rows": {k: {"adapter_id": v["row"]["adapter_id"], "role": v["row"]["role"],
                           "framework": v["row"]["framework"], "revision": v["revision"],
                           "binary_sha256": summary["binaries"][v["row"]["framework"]]["sha256"]}
                       for k, v in eligible.items()},
              "blocked": dict(blocked), "repeats": args.repeats, "order": measured_order(args.repeats),
              "dataset_item": ami.get("item_id"), "cooldown_s": args.cooldown_s,
              "replay": "realtime 1x, 20 ms frames, queue 32, block, telemetry 1 s, delay_ms 0"}
    write_new(out / "matrix.json", matrix)
    if args.skip_measured or not eligible:
        summary["status"] = "NOT_RUN" if not eligible else "PARTIAL"
        return finish(0 if eligible else 3)

    # Measured repetitions: one fresh process per run, alternating framework order.
    duration = int(ami["crop"]["duration_samples"])
    failures: dict[str, int] = {}
    first = True
    for rep, role, frameworks in measured_order(args.repeats):
        for framework in frameworks:
            key = next((k for k, v in eligible.items() if v["row"]["role"] == role and v["row"]["framework"] == framework),
                       None)
            if key is None or key in blocked:
                continue
            item = eligible[key]
            config = out / "configs" / f"{key}.yaml"
            if not config.exists():
                config.write_text(config_yaml(item["row"], item["revision"], Path(ami["manifests"][role]),
                                              ami["item_id"]))
            for attempt in ("", "-retry1"):
                if not first:
                    time.sleep(args.cooldown_s)
                first = False
                run_id = f"{key}-rep{rep}{attempt}"
                before = host_conditions()
                argv = [SANDBOX, "-p", DENY_NETWORK, str(binaries[framework]), "run", "--config", str(config),
                        "--runs-dir", str(out / "runs"), "--run-id", run_id]
                result = supervised(argv, run_env(item["row"], out / "profiles", item["entry"]), run_timeout_s(duration),
                                    out / "logs" / f"{run_id}.log")
                validate = subprocess.run([str(binaries[framework]), "validate", "--run", str(out / "runs" / run_id)],
                                          capture_output=True, text=True, timeout=1800, check=False) \
                    if (out / "runs" / run_id).is_dir() else None
                status = "valid" if result["exit_code"] == 0 and validate and validate.returncode == 0 else "failed"
                ledger.append({"kind": "measured", "row": key, "repetition": rep, "run_id": run_id,
                               "retry_of": f"{key}-rep{rep}" if attempt else None, "argv": argv, "network": "denied",
                               **result, "validate_exit_code": validate.returncode if validate else None,
                               "validate_tail": (validate.stdout + validate.stderr)[-1500:] if validate else None,
                               "conditions_before": before, "conditions_after": host_conditions(), "status": status})
                if status == "valid":
                    break
            else:
                failures[key] = failures.get(key, 0) + 1
                blocked[key] = f"repetition {rep} failed twice (one unchanged retry); remaining repetitions skipped"
    for key in eligible:
        summary["rows"][key] = "blocked" if key in blocked else "measured"

    # One 60 s mock pacing/integrity check per final binary (not a P01-P04 rerun).
    for binary in sorted({str(binaries[v["row"]["framework"]]) for v in eligible.values()}):
        tag = sha256_file(Path(binary))[:12]
        fixtures = out / f"mock60-{tag}"
        subprocess.run([str(ROOT / ".venv/bin/python"), str(ROOT / "scripts/generate_fixtures.py"), "--long-seconds", "60",
                        "--out", str(fixtures)], check=True, capture_output=True, timeout=600)
        config = out / "configs" / f"mock60-{tag}.yaml"
        config.write_text(config_yaml(None, None, fixtures / "manifest.json", "long-60s", mock=True))
        run_id = f"mock60-{tag}"
        result = supervised([binary, "run", "--config", str(config), "--runs-dir", str(out / "runs"), "--run-id", run_id],
                            run_env(None, out / "profiles", None), 900, out / "logs" / f"{run_id}.log")
        ledger.append({"kind": "mock_pacing_60s", "binary": binary, "run_id": run_id, **result,
                       "status": "pass" if result["exit_code"] == 0 else "fail"})
    summary["status"] = "measured"
    return finish(0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--out", required=True)
    ver = sub.add_parser("verify")
    ver.add_argument("--snapshot", required=True)
    ver.add_argument("--out", required=True)
    vend = sub.add_parser("vendor-speech")
    vend.add_argument("--dest", default=str(SPEECH_VENDOR))
    check = sub.add_parser("verify-speech", help="read-only identity check of an existing owned speech-swift copy")
    check.add_argument("--dest", default=str(SPEECH_VENDOR))
    check.add_argument("--out", help="also write the report to this NEW file")
    camp = sub.add_parser("campaign")
    add_campaign_arguments(camp)
    args = parser.parse_args()

    if args.command == "snapshot":
        write_new(Path(args.out), take_snapshot())
        print(f"snapshot written: {args.out}")
        return 0
    if args.command == "verify":
        before = json.loads(Path(args.snapshot).read_text())
        after = take_snapshot()
        result = compare_snapshots(before, after)
        write_new(Path(args.out), {"comparison": result, "snapshot": after})
        print(f"protected inputs: {result['status']}")
        for problem in result["problems"]:
            print(f"  {problem}")
        return 0 if result["status"] == "pass" else 9
    if args.command == "vendor-speech":
        print(json.dumps(vendor_speech(Path(args.dest).resolve()), indent=2))
        return 0
    if args.command == "verify-speech":
        report = verify_speech(Path(args.dest).resolve())
        if args.out:
            write_new(Path(args.out), report)
        print(json.dumps(report, indent=2))
        return 0 if report["status"] == "pass" else 9
    return run_campaign(args)


if __name__ == "__main__":
    sys.exit(main())
