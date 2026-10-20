# apple-silicon-voice-engine

A fully on-device, real-time voice intelligence engine for Apple Silicon, combining streaming ASR, speaker diarization, VAD, and performance benchmarking.

## Status: Phase 0 (M1–M7)

Phase 0 builds the **measurement harness** that later ASR and diarization
frameworks will be benchmarked with. It uses mock adapters only: no models, no
microphone, no services. It never claims recognition quality. The readiness
decision and its evidence are in `PHASE_0_READINESS_REPORT.md`.

| Milestone | Scope |
|---|---|
| M1 | scaffold, hash-locked dependencies, versioned schemas, strict config |
| M2 (+ hardening) | WAV validation/decode, downmix, SRC with disclosed endpoint policy, spool, three replay modes, bounded queue |
| M3 | adapter contracts, deterministic scripted mocks, typed event payloads, synthetic Gate A dataset |
| M4 | experiment runner, bounded recorder, lifecycle, failure/cancellation, provenance |
| M5 | WER/CER/DER/JER with hand-derived goldens, timing/resource metrics, process telemetry, `voicebench run` |
| M6 | `validate`, `compare`, `export`; schema 1.0 frozen |
| M7 | V01–V20 acceptance, P01–P04 characterization, enforced-offline smoke, readiness report |

## Using it

```sh
swift build -c release
.build/release/voicebench run --config configs/mock-step.yaml --runs-dir runs --run-id example
.build/release/voicebench validate --run runs/example
.build/release/voicebench export --run runs/example --out exports/example
.build/release/voicebench compare --runs runs/a runs/b --profile accuracy --out comparisons/ab
.build/release/voicebench validate --dataset datasets/manifests/hindi-pending.json
```

See `docs/cli.md` for flags and exit codes, and `docs/phase1-adapter-guide.md` for
adding a real adapter.

## Requirements (verified environment)

- macOS 26.6.2 on Apple Silicon (arm64). The package floor is macOS 13, but
  running on older OS versions is untested.
- Swift 6.3.2. With **Command Line Tools only**, use `scripts/swift_test.sh`
  for tests (see docs/decisions.md, DEC-003).
- Python 3.12 at `/opt/homebrew/bin/python3.12`.

## Setup

```sh
/opt/homebrew/bin/python3.12 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r analysis/requirements-dev-macos-arm64-py312.lock
.venv/bin/python -m pip check
swift build
```

Network access is needed only for this setup step (SwiftPM and PyPI). After
setup, all commands are local.

## Tests and checkpoints

```sh
export PYTHONPATH="$PWD/analysis/src" MPLBACKEND=Agg
scripts/swift_test.sh                                   # all Swift tests
.venv/bin/python -m pytest analysis/tests -q            # Python + Swift/Python parity (needs `swift build`)
.venv/bin/python scripts/generate_fixtures.py --small --out datasets/fixtures --verify
.venv/bin/python scripts/checkpoint.py M1 --out evidence/M1
.venv/bin/python scripts/checkpoint.py M2 --out evidence/M2
.venv/bin/python scripts/checkpoint.py M2-hardening --out evidence/M2-hardening   # includes a Thread Sanitizer run
.venv/bin/python scripts/checkpoint.py M6 --out evidence/M6        # M3..M6 groups exist as well
.venv/bin/python scripts/e2e.py --voicebench .build/release/voicebench --out evidence/e2e
```

M7 acceptance (long campaigns are separate, explicit steps):

```sh
.venv/bin/python scripts/generate_fixtures.py --long-seconds 30 --long-seconds 60 --long-seconds 720 --out datasets/fixtures/generated-large
.venv/bin/python scripts/characterize.py --voicebench .build/release/voicebench --out evidence/M7/performance   # ~20 min, real time
.venv/bin/python scripts/determinism.py --voicebench .build/release/voicebench --config configs/mock-step.yaml --repeats 3 --out evidence/M7/determinism
bash scripts/offline_smoke.sh .build/release/voicebench .venv/bin/python evidence/M7/offline
.venv/bin/python scripts/acceptance.py --voicebench .build/release/voicebench --gate-a --out evidence/M7/acceptance
.build/release/voicebench validate --suite gate-a --evidence-dir evidence/M7
```

`checkpoint.py` records every command (argv, cwd, timing, exit code, full log)
in `evidence/<M>/checkpoint.json`, along with JUnit/xUnit XML and the
measured evidence files. `evidence/` and `runs/` are git-ignored.

## Layout

```text
Sources/BenchmarkSupport   JSON model, strict JSON/YAML, config, manifests, annotations, events, clocks
Sources/AudioCore          WAV inspection/decode, downmix, AVAudioConverter SRC, PCM spool, sample clock
Sources/Replay             bounded queue, virtual clock, frame iterator, replay scheduler, trace/coverage
Sources/AdapterContracts   streaming adapter protocols, events, output validation
Sources/MockAdapters       scripted ASR and diarization mocks, fixture scripts
Sources/CTelemetry         C shim: getrusage CPU, task_info memory, SDK facts
Sources/Telemetry          process sampler, capability report
Sources/Experiment         runner, recorder, lifecycle, provenance, Python bridge
Sources/BenchmarkCLI       voicebench run/validate/compare/export (+ hidden `dev` tools)
Tests/                     Swift Testing suites per module
analysis/                  Python analysis package (schemas, scoring, validation, compare, export), hash-locked
schemas/v1/                14 JSON Schema (2020-12) documents, frozen (schemas/SCHEMA_BUNDLE_V1.sha256)
testdata/                  shared schema corpus, count goldens
datasets/                  generated synthetic fixtures; English/Hindi manifests (pending, Gate B)
configs/                   authored YAML experiment configs
docs/                      contracts, decisions, API verification, dependencies, implementation log
scripts/                   fixtures, checkpoints, e2e, determinism, characterization, offline smoke, acceptance
```
