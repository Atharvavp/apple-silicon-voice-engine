# Phase 1 results: FluidAudio vs speech-swift (English ASR and Sortformer)

**Status: NOT_RUN.** The implementation, builds and model-free verification are done. No model
or AMI measurement could start because the owner inputs file (`phase1-inputs.json`) does not exist,
so there is no model permission, no license acceptance and no approved AMI data. No accuracy, time
or memory numbers exist, and none are implied below.

Session 2026-10-21. Evidence packet: `evidence/phase1/one-shot/20261021-s1/` (git-ignored).
Start state: `b6143b6cd9db3adbe29c21671f82167ea816286e`, clean. Frozen schema bundle
`cc647ac9…8918407` (14 files), unchanged at the end.

## Rows

| Row | Configuration | Status | Reason |
|---|---|---|---|
| D1 | FluidAudio Sortformer v2.1 low-context (`fastV2_1`) | blocked | no owner inputs: model files/permission and AMI data absent |
| D2 | speech-swift Sortformer v2.1 `.streaming` | blocked | same |
| A1 | FluidAudio Parakeet EOU 120M, 320 ms | blocked | same |
| A2 | speech-swift Parakeet EOU 120M, INT8 | blocked | same |
| V1/V2 | VoxConverse | skipped_optional | no lawful audio with matching RTTMs supplied |

The campaign and report were run for real against the missing inputs path and produced
`campaign/campaign-summary.json` (NOT_RUN, four blocked rows) and `report/PHASE_1_RESULTS.md`.

## What was built and verified

| Item | Result | Evidence |
|---|---|---|
| Fluid-only release build (`PHASE1_FRAMEWORKS=fluid`) | success, Command Line Tools only, 0 warnings | `build/fluid-release-attempt2.log` |
| speech-only release build | success after one manifest-only patch (below); MLX compiled without Metal tooling, no `default.metallib` | `build/speech-release-attempt4-owned-copy.log` |
| Joint release build (`both`) | success; `--version` lists both frameworks | `build/both-release-final.log` |
| Swift suite, `both` graph (211 tests) | 210 pass; 1 expected failure: `buildFactsComeFromTheCompiler` hard-codes deployment target 13.0, framework builds need 15.0 | `tests/swift-tests-both-final.log` |
| Swift suite, default `none` graph (211 tests) | 210 pass in the full run; the 1 failure (`cancellationStopsRealtimeReplayPromptly`, 243 ms vs 200 ms) ran concurrently with the offline smoke and passed 3/3 when rerun alone | `tests/swift-tests-none.log` |
| New `RealAdapterTests` (7 suites) | pass | same logs |
| Python suite (261 tests incl. 26 new) | 261 pass on the final joint binary | `tests/pytest-final.log`, `.xml` |
| `generate_fixtures.py --small --verify` | pass | `regressions/fixtures-verify.log` |
| `e2e.py` (fresh output) | 45/45 steps pass | `regressions/e2e.log` |
| `determinism.py`, 3 processes | pass | `regressions/determinism.log` |
| `offline_smoke.sh` (deny-network sandbox) | pass; denial enforced with positive/negative controls | `regressions/offline/` |
| Protected inputs (schemas, scoring, contracts, runner, Phase 0 evidence) | unchanged | `snapshot-start.json`, `snapshot-end.json` |

Binaries (SHA-256): `phase1-both` `30c23bf8…`; `Package.resolved` (`both`, committed) `aee60879…`.
Per-variant locks are in `build/Package.resolved.{none,fluid,speech,both}`. ArgumentParser 1.8.2
and Yams 6.2.2 keep their original revisions in every lock. The `phase1-fluid` and `phase1-speech`
binaries predate the final lock-type change in `CallbackMailbox` (no behavior change); use the joint
binary.

## Integration findings (verified facts, not performance results)

1. **speech-swift and the harness both declare a target named `BenchmarkSupport`.** SwiftPM rejects
   the graph, and `moduleAliases` cannot rename a target outside the product's dependency closure. The fix
   is an owned copy of the pinned commit (`vendor/speech-swift`, recreated by
   `scripts/run_phase1.py vendor-speech`) with one manifest-only patch that renames speech-swift's
   benchmark-only target. No inference, preprocessing or decoding source changed (DEC-079).
2. **Both frameworks build with Command Line Tools only** (Swift 6.3.2, SDK 26.5). Full Xcode was
   not required to compile. Whether speech-swift's CoreML paths run without an MLX metallib is
   unverified until a model runs.
3. **SwiftPM artifact downloads stalled twice in this agent session.** This happened on FluidAudio's
   unused NeMo artifact and on speech-core's artifact, apparently at a keychain credential lookup.
   `--disable-keychain` avoided it. FluidAudio's NeMo artifact is downloaded at resolution even with
   only the `Diarizer` trait, but it is never linked.
4. **The pinned APIs differ in ways that affect comparability.** Fluid's Sortformer timeline uses
   pass-through 0.5 thresholds, while speech-swift applies 0.3 s minimum speech and a 0.15 s gap
   merge and compacts speaker IDs. speech-swift reports Float seconds, so 1199.92 s maps to a sample one
   past the frame boundary. The speech EOU loader has no offline or cache parameter and hard-codes
   `.cpuAndGPU` unless `SPEECH_COREML_COMPUTE_UNITS` is set. Fluid's `process(audioBuffer:)` returns
   empty text and delivers cumulative text only via callback.

## Remaining external prerequisites (owner)

1. Write `phase1-inputs.json` (format in `docs/phase1/README.md`) with absolute roots.
2. Accept the NVIDIA Open Model License and conversion terms for the four model repositories, and provide
   their selected files at full 40-character revisions (local) or authorize acquisition.
3. Provide official AMI ES2008a headset mix and manual annotations v1.6.2 under the approved terms.
4. Decide on two points: the owned speech-swift copy (DEC-079), and whether the deployment-target test
   should become variant-aware.
5. Provide unattended AC-powered time for the runs: about 4 h of paced audio for the four rows × 3, plus overhead.

## Reproduce

```sh
.venv/bin/python scripts/run_phase1.py vendor-speech
PHASE1_FRAMEWORKS=both swift build --disable-keychain -c release --scratch-path .build/phase1-both
# then the stage commands in docs/phase1/README.md with the real $INPUTS and a new $SESSION
```

No LinkedIn draft is included: there are no measured findings to report.
