# apple-silicon-voice-engine

A fully on-device, real-time voice intelligence engine for Apple Silicon, combining streaming ASR, speaker diarization, VAD, and performance benchmarking.

## Status: Phase 0, Checkpoint 1 (M1–M2)

Phase 0 builds the **measurement harness** that later ASR and diarization
frameworks will be benchmarked with. It uses mock adapters only: no models, no
microphone, no services. It will never claim recognition quality.

| Milestone | State |
|---|---|
| M1: scaffold, dependencies, versioned schemas, strict config | done, checkpoint passed |
| M2: WAV validation/decode, downmix, SRC, spool, chunking, real/accelerated/step replay, bounded queue | done, checkpoint passed |
| M2 hardening: queue concurrency, audio integrity, resampling edges (docs/M2_HARDENING_REPORT.md) | done, checkpoint passed |
| M3–M7: mock adapters, runner, scoring, telemetry, CLI, acceptance | not started |

The `voicebench` CLI currently offers `--help` and `--version` only. `run`,
`validate`, `compare` and `export` arrive in M4–M6. They aren't stubbed, so
nothing can report a fake success.

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
```

`checkpoint.py` records every command (argv, cwd, timing, exit code, full log)
in `evidence/<M>/checkpoint.json`, along with JUnit/xUnit XML and the
measured evidence files. `evidence/` and `runs/` are git-ignored.

## Layout

```text
Sources/BenchmarkSupport   JSON model, strict JSON/YAML, config, manifests, annotations, events, clocks
Sources/AudioCore          WAV inspection/decode, downmix, AVAudioConverter SRC, PCM spool, sample clock
Sources/Replay             bounded queue, virtual clock, frame iterator, replay scheduler, trace/coverage
Sources/BenchmarkCLI       voicebench (help/version + hidden `dev` parity tools)
Tests/                     Swift Testing suites per module
analysis/                  Python analysis package (schemas, doctor), hash-locked requirements
schemas/v1/                13 JSON Schema (2020-12) documents
testdata/                  shared schema corpus, count goldens
datasets/                  generated synthetic fixtures; English/Hindi manifests (pending, Gate B)
configs/                   authored YAML experiment configs
docs/                      contracts, decisions, API verification, dependencies, implementation log
scripts/                   fixture generator, checkpoint runner, Swift test wrapper
```
