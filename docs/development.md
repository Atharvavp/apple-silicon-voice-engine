# Development and checks

## Environment

Run `bash scripts/setup.sh` once (see the [README](../README.md#quick-start-mock-adapters)). Then set
the analysis environment explicitly in each shell:

```sh
export PYTHONPATH="$PWD/analysis/src" MPLBACKEND=Agg PYTHONDONTWRITEBYTECODE=1 PHASE1_FRAMEWORKS=none
```

The Swift tests and the Python parity tests both need `.venv`. Swift experiment tests run the
analysis interpreter at `<repo>/.venv/bin/python`, and the Python suite runs the built CLI. Without
setup, about 70 Swift tests fail with "python_executable … is not an executable file". That is a
missing prerequisite, not a regression.

## Check matrix

| Check | Command | Needs |
|---|---|---|
| Default debug build | `swift build --disable-keychain` | macOS, Swift 6.2+ toolchain |
| Default release build | `swift build --disable-keychain -c release` | same |
| Swift suite (model-free) | `bash scripts/swift_test.sh --disable-keychain` | `.venv`; Command Line Tools or Xcode |
| Python suite, including Swift parity and CLI tests | `.venv/bin/python -m pytest analysis/tests -q` | `.venv`, a debug build (or `VOICEBENCH_BIN=$PWD/.build/release/voicebench`) |
| Dependency integrity | `.venv/bin/python -m pip check` | `.venv` |
| Environment doctor | `.venv/bin/python -m phase0_analysis doctor --schemas schemas/v1 --project-root . --out <new-file>` | `.venv` |
| Shared schema corpus | `.venv/bin/python -m phase0_analysis schema-check --schemas schemas/v1 --fixtures testdata/schemas --out <new-file>` | `.venv` |
| Fixture bytes | `.venv/bin/python scripts/generate_fixtures.py --small --out datasets/fixtures --verify` | `.venv`; byte equality is verified on macOS (resampled fixtures depend on the SDK) |
| Beginner smoke | `bash scripts/smoke.sh` | setup |
| Release end-to-end CLI checks | `.venv/bin/python scripts/e2e.py --voicebench .build/release/voicebench --out <new-dir>` | release build |
| Linux-portable Python subset | see [CI](#continuous-integration) | Python 3.12 only |

`pytest` fails, rather than skipping, when the CLI binary is missing: parity checks must not
quietly disappear.

### Cancellation timing

`ReplayModeTests` check cancellation in two ways. One is deterministic (a test clock whose
sleeps end only on cancellation). The other runs on the real clock and checks structure, not
time: it must throw `CancellationError` and must stop before delivering all 600 chunks of the 12 s
stream. Latency depends on machine load. Under the parallel suite it was 30–491 ms over 10 local
runs, 0.2 ms in isolation, and up to 9.4 s on a 3-core GitHub runner. The 5 s and 200 ms targets
are therefore opt-in, and they are meaningful only on an otherwise idle host:

```sh
VOICEBENCH_TIMING_CHECKS=1 bash scripts/swift_test.sh --disable-keychain \
    --filter 'ReplayModeTests/cancellationStopsRealtimeReplayPromptly'
```

### Optional SDK builds (model-free)

These builds compile the real wrappers. Their tests use fake backends and stub Core ML models,
which shows that the wrapper contracts hold. It does not show recognition quality. Build in a
**separate checkout**, because the optional graphs rewrite `Package.resolved`:

```sh
.venv/bin/python scripts/run_phase1.py vendor-speech            # fetches speech-swift 3f58a58a + patch
.venv/bin/python scripts/run_phase1.py verify-speech            # read-only identity check
cp docs/phase1/evidence/20261021-s2/Package.resolved.both Package.resolved   # historical 41-pin lock
PHASE1_FRAMEWORKS=both swift build --disable-keychain -c release --scratch-path .build/phase1-both
VOICEBENCH_BIN="$PWD/.build/phase1-both/release/voicebench" PHASE1_FRAMEWORKS=both \
    bash scripts/swift_test.sh --disable-keychain --scratch-path .build/phase1-both
VOICEBENCH_BIN="$PWD/.build/phase1-both/release/voicebench" .venv/bin/python -m pytest analysis/tests -q
```

On 2026-10-27 this produced a binary that lists both frameworks. The Swift suite gave 220 tests
passed, with 5 known issues (the documented native speech-swift EOU loss cases). The Python suite
gave 289 passed. The historical lock was reused without any pin change. A source rebuild is a new
binary identity (its SHA-256 differs from the historical campaign binary).

### Historical Phase 0 tooling

`scripts/checkpoint.py`, `acceptance.py`, `characterize.py`, `determinism.py` and `offline_smoke.sh`
reproduce the Phase 0 milestone evidence. Each one refuses an existing output directory, so pass a
new one each time. `characterize.py` runs about 20 minutes in real time. `checkpoint.py M2-hardening`
includes a Thread Sanitizer run.

## Continuous integration

`.github/workflows/ci.yml` defines two jobs (runner labels and action versions checked against GitHub's documentation on 2026-10-27; **no workflow run has happened yet**). Neither downloads a model or dataset or runs one.

| Job | Runner | What it proves |
|---|---|---|
| `python-portable` | `ubuntu-24.04`, Python 3.12 | Scorer goldens, timing/resource metric arithmetic, follow-up audit helpers, vendor verification and schema corpus checks that need no Swift binary. It does **not** validate Swift, audio conversion, Core ML or anything Apple-specific |
| `macos-mock` | `macos-26` (arm64, GitHub-hosted M1) | Default-graph debug and release builds, the full model-free Swift suite, the full Python suite against the built CLI, fixture bytes, doctor, schema corpus and the beginner smoke. The mock harness only; no real-model inference |

Optional SDK builds and real-model runs are **manual** gates (above and in the
[Phase 1 guide](phase1/README.md)), recorded with dated evidence. They are not run in CI. The
`macos-26` runner image uses Xcode rather than the Command Line Tools, on M1 hardware, so its SDK and
toolchain differ from the tested host. If an SDK-dependent
golden (for example the resampled fixture bytes) differs there, that is a portability finding to
investigate. The fix is never to rewrite goldens.

## Change rules

- Schemas, metric and normalizer definitions, and the event vocabulary are **frozen at v1**
  (`schemas/SCHEMA_BUNDLE_V1.sha256`). Changing them needs a new versioned policy or schema, not an edit.
- Fixture bytes are generated. Change `scripts/generate_fixtures.py`, regenerate, and confirm
  `--verify` reports 0 mismatches.
- Outputs are never overwritten: new run IDs, new `--out` directories.
- Keep `Package.resolved` on the default graph. Do not commit an optional-graph lock.
- The README architecture diagram is generated: edit `docs/assets/make_architecture_svg.py`, run it
  with `python3`, and commit both SVGs.
- Add tests at the level of the behavior you change. The existing suites already cover decoding,
  resampling, queue races, replay, contracts, lifecycle and scoring.
