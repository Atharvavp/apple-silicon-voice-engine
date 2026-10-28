# Implementation log

## 2026-10-20: Checkpoint 1 (M1 + M2)

**Authorization:** the owner's execution prompt authorizes Phase 0 only, Checkpoint 1
(M1–M2), and says to stop before M3. Plan baseline: `PHASE_0_CLAUDE_IMPLEMENTATION_PLAN.md`
(19 Oct 2026; on-disk copy SHA-256 `c6295ef8…ca365e`). It isn't copied into this
repo; see DEC-002.

### Environment reconnaissance (observed)

- Repository: the existing Git repo at `~/workspace/content/linkedin/apple-silicon-voice-engine`,
  containing only `README.md` (commit `4a5d3ab`). No `AGENTS.md` was found in the
  repo or its parents. Plan paths are applied here (DEC-001).
- Swift 6.3.2, Command Line Tools only (no Xcode), SDK 26.5, macOS 26.6.2 (25G83),
  arm64. `sysctl` was readable this time: `Mac17,3`, Apple M5, 16 GiB. This
  resolves the plan's "hardware unconfirmed" item for this machine.
- `import XCTest` fails, and `import Testing` works only with explicit
  framework flags. This led to the `scripts/swift_test.sh` wrapper (DEC-003),
  verified with a scratch package in which a deliberately failing expectation
  exits nonzero.
- Network: PyPI and GitHub were reachable for setup. Copying the plan out of
  the client folder was blocked by the permission classifier and not retried
  (DEC-002).

### M1: scaffold, dependencies, schemas, config

1. Created `Package.swift` (tools 6.0, macOS 13 floor) and resolved
   swift-argument-parser 1.8.2 and Yams 6.2.2 to exact revisions (`Package.resolved`).
2. Created the Python 3.12.14 venv. Installed pip-tools 7.6.2 (BSD-3-Clause,
   verified on PyPI). Compiled hash locks for runtime and dev (about 60 minutes;
   pip-tools downloads every published wheel to hash it). Installed with
   `--require-hashes`; `pip check` is clean. The resolved graph contains no
   model or inference packages.
3. Wrote `BenchmarkSupport`: `JSONValue`, `StrictJSON`, `JSONWriter`
   (canonical/pretty/compact), `FieldReader`, `StrictYAML`, `Identifiers`,
   `SchemaVersion`, `CheckedMath`, `ReplaySpeed`, `RunClock`
   (continuous + fake), `RunConfig` with overrides, settings hash and path
   resolution, `DatasetManifest`, `AnnotationDocument`, `EventEnvelope`,
   `MetricRecord`, `RunStatus`, and `DocumentKind`.
4. `voicebench` CLI: `--help`, `--version`, and hidden `dev roundtrip|canonical|config-settings`
   used only by the parity tests. No `run` stub.
5. 13 schemas in `schemas/v1/`, plus a 95-document shared corpus
   (`testdata/schemas/{valid,invalid,semantic-invalid}`).
6. `analysis/phase0_analysis`: strict loader, offline schema store, `doctor`,
   `schema-check`, and tests including Swift↔Python parity through the built binary.
7. `configs/mock-step.yaml`, English and Hindi pending manifests, and `scripts/checkpoint.py`.

Issues found by tests and fixed:

- Quoted YAML scalars were rejected as explicitly tagged. Yams reports `str` for
  `quoted_implicit`, so the rule was narrowed (DEC-005).
- A Yams tag-mutation side effect on keys was found in its source and
  documented (DEC-005).
- `frame_ms: 20.0` passed the JSON Schema enum. An explicit integer type was
  added (DEC-007).
- The doctor's name normalization didn't fold `.`, so `pyannote_audio` wasn't
  matched against `pyannote.audio`. It now uses PEP 503 normalization.
- pyannote packages declare no license metadata. The doctor now reads their
  bundled MIT `LICENSE` files instead of reporting UNDECLARED.
- A `SendableMetatypes` warning on generic enum reads was removed.
- Two event payload defects aren't caught by Swift until M3. They're tracked
  as explicit, test-asserted gaps (DEC-010).

**M1 checkpoint:** `evidence/M1/checkpoint.json` = **pass**. 8/8 commands:
swift build, `--version`, `--help`, 35 Swift test functions (BenchmarkSupport),
`pip check`, 95 pytest cases, doctor (20/20 checks), and schema-check
(95 documents, 0 unexpected).

Process note: the M2 sources were *drafted* while the lock downloaded, but no
M2 test or checkpoint ran until the M1 checkpoint had passed in the locked
environment.

### M2: WAV, conversion, replay

1. `scripts/generate_fixtures.py` writes 23 valid WAVs, 20 malformed files, a
   generation manifest with hashes, and `testdata/goldens/audio-counts.json`
   (counts and chunk plans from Python integer math, independent of the Swift
   code). `--verify` checks byte reproducibility: 45/45 files.
2. AudioCore: `WAVInspector` (strict RIFF), `WAVDecoder` (AVAudioFile Float32,
   4,096-frame blocks), `MonoDownmixer`, `SampleRateConverter` (streaming,
   EOS drain, ±1 endpoint wrapper), `AudioPreparer` (two-stage spool),
   `PCMSpool` (exclusive writer, reader), `SampleClock`/`ChunkPlan`, and
   `AudioChunk`/`OwnedMonoPCM`.
3. Replay: `BoundedQueue` (actor; block/drop_newest; close/fail/cancel),
   `VirtualClock`, `FrameIterator`, `ReplayScheduler` (paced producer/consumer
   for real/accelerated; acknowledged coordinator for step), and `ReplayTrace`
   (coverage and accounting verification, evidence lines).
4. Tests: AudioCoreTests (23 functions) and ReplayTests (23 functions).
   Measured values are written under `evidence/M2/swift-evidence/V01…V11`.

Issues found and fixed:

- `FileManager.createFile` overwrote existing spools; replaced with `O_EXCL` (DEC-019).
- The converter input block is `@Sendable`, so its feed state is now
  lock-protected (DEC-015).
- `#expect` with a key-path `allSatisfy` didn't compile; the value is now
  computed first.

Probe results (`evidence/M2/swift-evidence/V02/src-probes.json`): native
SRC counts match the half-up rule on all 8 resampled fixtures (no trim or
extend), the impulse is aligned exactly, in-band RMS ratio is 0.9999996, DC
error is 1.2e-7, the 12 kHz tone is attenuated 125.9 dB, and output is
identical across input block splits. These confirm the D2 assumptions, so
there was no reason to stop M2.

Real-clock diagnostic (`V07/realtime-short.json`, 1 s, n = 50, not P01): wake
error p50 4.0 ms, p95 4.6 ms, max 41.3 ms in the checkpoint run (p50 5.0 / p95
9.0 / max 9.5 ms in an earlier run). Two caveats:

- A scratch probe showed the same magnitude for every sleep tolerance, for
  every task priority, and for a raw `mach_wait_until` baseline. The latency
  is host-level.
- Swift Testing runs tests in parallel, so this diagnostic shares the CPU with
  other suites. The single 41 ms outlier is consistent with that.

**For M7:** P01/P02 campaigns must run as dedicated, serialized processes on a
controlled idle machine, not inside `swift test`.

**M2 checkpoint:** `evidence/M2/checkpoint.json` = **pass**. 7/7 commands:
fixture reproducibility, swift build, AudioCoreTests (23), ReplayTests (23),
full Swift regression (81 functions, 0 failures, 0 skips), full pytest
regression (95 cases, 0 failures, 0 skips), and schema-check.

### Plan V-IDs touched (foundations only; mandatory V-IDs are closed in M7)

| V-ID | M1/M2 foundation evidence |
|---|---|
| V01 | `WAVDecoderTests`; `V01/formats.json` (23 supported, 20 malformed, each with its expected typed error) |
| V02 | `ConversionTests`; `V02/*.json` |
| V03 | `SampleClockTests`, `ClockTests`; `V03/clock.json` |
| V04 | `ChunkContinuityTests`, `everyFrameSizeCoversAllSamples`; `V04/*` |
| V05 | Step determinism over 3 in-process runs (`V05/step-run-*.jsonl`); the 3-process version is M7 |
| V06 | Accelerated 4, 1.5 and 100× exact rational deadlines (`V06/*`) |
| V07 | Absolute-deadline fake-clock test; short real-clock diagnostic (`V07/*`) |
| V10 | `ReplayClockDomainTests` (virtual/real separation) |
| V11 | Queue unit tests; block and drop_newest slow-consumer traces (`V11/*`) |
| V13 | Schema corpus, YAML strictness, Swift↔Python parity |
| V19 | Doctor (no model packages, offline `$ref` resolution); enforced offline run is M7 |

### Remaining for later checkpoints

M3 adapter contracts, mocks and typed event payloads (closing the DEC-010
gap). M4 runner, recorder, lifecycle, PythonBridge and signal handling. M5
scoring goldens, C telemetry shim and sampler. M6 CLI
validate/compare/export. M7 acceptance V01–V20, P01–P04, enforced offline
smoke test and readiness report.

## 2026-10-20: M2 hardening (H1–H3)

**Authorization:** the owner's hardening prompt. M2 hardening only; stop for review afterwards. No M3–M7 work.
Full report: `docs/M2_HARDENING_REPORT.md`.

1. Probed raw AVAudioConverter counts over 9 rate pairs × 24 lengths before
   changing any code. 4 of the 9 pairs differ from the half-up count by exactly ±1
   for some lengths, which falsified the DEC-018 note "never needed".
2. Refactored conversion into `AudioPreparer.resample(...)`, which is testable on
   spools directly. Added `EndpointPolicy` (`allow_one_frame_v1` default, `strict`),
   `endpoint_status`, `ConversionRecord.validate()` and `requireExactEndpoints()` (DEC-025).
3. Removed the silent `FrameIterator.next()` path (DEC-027). Added the replay→spool
   SHA-256 binding, checked at end of stream (DEC-028).
4. Added the `BoundedQueue.invariantViolations` diagnostic (DEC-030) and the
   `withTimeout` test helper (DEC-031).
5. Found that Swift emitted conversion keys the runtime-summary schema rejects.
   Aligned the schema, added the corpus target `runtime-summary-conversion`,
   `voicebench dev prepare-audio`, and Python parity tests (DEC-029).
6. Added 6 very short WAV fixtures (51 files total, reproducible) and new
   suites `QueueHardeningTests`, `AudioIntegrityTests` and `ResamplingEdgeTests`.
7. While reviewing my own new tests, found two by-design deadlocks (waiting on
   blocked senders with no consumer). Fixed them before their first run.
8. Thread Sanitizer works under the Command Line Tools. The instrumented bundle
   was verified with `otool -L`, and TSan was added as the last step of the
   hardening checkpoint.
9. Version bumps: `voicebench 0.2.1-phase0-m2-hardening`, analysis `0.2.1`.

**Hardening checkpoint:** `evidence/M2-hardening/checkpoint.json` = **pass**, 12/12:
fixtures 51/51, build, H1 in 3 processes (8 functions each), H2 (6), H3 (7),
the full Swift regression (102 functions, 0 failures, 0 skips), pytest (102, 0
failures, 0 skips), schema-check (99 documents), doctor, and TSan (33 tests, 0
reports). The M1 and M2 checkpoint groups were rerun on the final code into
`evidence/M2-hardening/regression-M{1,2}/`; both pass.

## 2026-10-20: M3–M5 (owner-authorized M3–M7 execution)

**Authorization:** the owner's M3–M7 execution prompt, with decisions DEC-026 (approve
`allow_one_frame_v1` default, keep `strict`) and DEC-008 (schema 1.0 mutable until the
first sealed benchmark run, then frozen with the bundle digest recorded), plus the
spool-integrity requirement (pre-replay and end-of-stream SHA-256). A later "resume"
prompt continued the same work after a session usage limit; the resumed session
re-inspected the tree and re-ran every regression before continuing (see "Resume" below).

**Inputs located:** the plan on disk matches the recorded hash (`c6295ef…ca365e`); it is
still not copied into the repo (DEC-002). The planning pack directory
(`~/Downloads/phase0_planning_pack`, PRD and architecture files) is **not readable** from
this session ("Operation not permitted"). Work used the plan, which embeds the locked
decisions and the FR/V-ID traceability, as M1–M2 did.

### M3: adapter contracts and mocks

- `AdapterContracts`: `StreamingAdapter` (+ `ASRAdapter`, `DiarizationAdapter`),
  `AdapterContext`, `ConsumeContext`, `StreamEnd`, `AdapterEvent`/`AdapterOutput`,
  `AdapterError`, `AdapterLifecycle`, `AdapterOutputValidator` (revision rules, ranges, roles).
- `MockAdapters`: `MockASRAdapter`, `MockDiarizationAdapter` (distinct actors), `FixtureScript`
  (hash-verified; causal triggers; fixture-declared faults), `ScriptPlayer` (missing-audio
  suppression), `SplitMix64`.
- Typed payload validation for all event families (DEC-032, closes DEC-010); new
  `adapter.diagnostic` family; new `fixture-script` schema; `audio.endpoint_policy` config field.
- Synthetic Gate A dataset (3 items) with hand-written references and scripts.
- Checkpoint `evidence/M3/checkpoint.json` = **pass** (8/8): 35 adapter-contract cases
  including the hand-derived `testdata/goldens/mock-events.json`; 136 Swift tests; 136 pytest.

### M4: runner, recorder, lifecycle, provenance

- `Experiment`: `RunPlanner` (preflight, all hashes against bytes on disk, before any run
  directory exists), `RunDirectory`/`AtomicFile`, `JSONLStream`/`SerialFileWriter`,
  `EventRecorder` (prefix freeze, single terminal append), `ProducerChannel`,
  `RecordingAdapterSink`, `ReplayEventObserver`, `PipelineWorker`, `PythonBridge`,
  `EnvironmentCapture`, `PredictionBuilder`, `RunSession` (lifecycle, bounded cleanup).
- Additive Replay hooks (DEC-045). `voicebench dev runtime-stage` for Python tests.
- Python `trace.py` (`logical_trace_v1` projection) and `validate.py` (stages, disclosures).
- Issues found and fixed: the Swift payload validator rejected a field added only to the
  JSON Schema (fixed in both); bounded cleanup waited for its own timer (task-group
  semantics, DEC-054); four test-design errors (determinism configs, blocked-producer
  scenario, distribution name, an always-true assertion) were corrected before acceptance.
- Checkpoint `evidence/M4/checkpoint.json` = **pass** (9/9): 27 Experiment tests (fault at
  every adapter stage, cancellation, strict endpoints, determinism, substitution), 15 pytest
  trace/validation tests, 163 Swift / 151 pytest regression, TSan over recorder and runner
  suites with 0 reports.

### M5: scoring and telemetry

- Python: `normalization.py`, `asr_metrics.py`, `diarization_metrics.py`, `timing.py`,
  `resources.py`, `score.py`; `score` and `validate` operations; goldens `asr.json`,
  `diarization.json`, `timing.json`, `telemetry.json` (all hand-derived).
- Swift: `CTelemetry` shim, `Telemetry` (`ProcessProbe`, `TelemetryCapabilities`,
  `TelemetrySampler`, `BuildFacts`), production `voicebench run` with SIGINT/SIGTERM
  cancellation and a summary that labels mock scores.
- End-to-end scores equal the hand derivations: `two-speaker-en` WER 0.4, CER 2/13, DER 0.25,
  JER 5/12; `two-speaker-hi` WER 1/3, CER 1/12, DER 0, JER 0; `endpoint-trim-en` all 0 with
  the trim disclosed.
- Checkpoint `evidence/M5/checkpoint.json` = **pass** (12/12): telemetry tests, 60 scoring
  tests, release build, two sealed release runs validated from Python, 174 Swift tests,
  211 pytest, schema-check 133 documents, doctor.

### Resume (after the session usage limit)

Re-inspection showed: no commits since `4a5d3ab`; M3 and M4 checkpoints passed; M5 code
present but no checkpoint. Full regressions were re-run: 211 pytest passed; 170 Swift tests
ran with one failure (`periodicSamplesUseAbsoluteDeadlinesWithoutCatchUp`), traced to the
DEC-062 phase-label bug and fixed. Remaining M5 work (production `run`, sealed-run and
scoring-failure tests, telemetry error tests, checkpoint) was then completed.

### M6: CLI validate/compare/export, schema freeze

- Swift: `ValidateCommand` (run / rescore / dataset / suite), `CompareCommand`, `ExportCommand`,
  `AnalysisCommands` + `DatasetValidator` (Experiment), usage errors mapped to exit 2.
- Python: `compatibility.py`, `compare.py`, `export.py` (CSV + Agg PNG); `compare`/`export`
  operations; `scripts/e2e.py`; `docs/cli.md`.
- Schema 1.0 frozen (DEC-072).
- Issues found and fixed: ArgumentParser's exit 64 for usage errors (G3 requires 2); a
  failed run's summary printed to stdout.
- The `--suite gate-a` path deliberately fails ("not available yet") until M7 wires it.
- Checkpoint `evidence/M6/checkpoint.json` = **pass** (9/9): Swift CLI tests, 18 Python
  compare/export/CLI tests, release build, `e2e.py` 45/45 on the release binary (successful
  runs in all modes, validate, rescore, compare compatible/incompatible/override/lossy/failed,
  export, and every negative exit category), 179 Swift tests, 230 pytest.

### M7: acceptance, characterization, readiness

- Tooling: `scripts/characterize.py` (P01–P04), `scripts/determinism.py`, `scripts/offline_smoke.sh`,
  `scripts/acceptance.py`; analysis `acceptance.py` and `readiness.py`; `validate --suite gate-a`;
  `docs/phase1-adapter-guide.md`; `PHASE_0_READINESS_REPORT.md`.
- Campaign (`evidence/M7/performance`, uncontrolled host, all 13 runs exit 0): P01 post-warm-up
  absolute admission error p95 8.96–9.06 ms (max ≈ 10.03 ms), 0 dropped; P02 720 s exact (11,520,000
  samples, 36,000 chunks), trend −136 ns per media second, final deviation 6.01 ms; P03 raw pairs;
  P04 every telemetry-on run took all expected periodic samples with 0 missed intervals.
- Determinism: 3 separate processes, identical `logical_trace_v1` event, prediction and metric
  projections; raw traces distinct.
- Offline: network denial proven by positive/negative controls; e2e 45/45 under the policy.
- Acceptance: V01–V20 all pass (every selection executed tests; 0 failures, errors or skips);
  `voicebench validate --suite gate-a` → pass 20/20 with the uncontrolled-host disclosure.
- Issues found and fixed: empty test selections could have passed silently (guard added, DEC-073);
  the readiness headline did not state the uncontrolled-host limitation (fixed); the automated
  SIGINT test closed the last API-ledger gap.
- Checkpoint `evidence/M7/checkpoint/checkpoint.json` = **pass** (9/9): fixtures reproducible,
  debug and pinned release builds, 179 Swift tests, 231 pytest, schema-check, doctor, Gate A suite,
  TSan over 61 concurrency tests with 0 reports. Final Python regression after the last edits:
  235 passed.
- **Decision: Gate A PASS with documented limitations; Gate B PENDING.** Stopped at Phase 0.
