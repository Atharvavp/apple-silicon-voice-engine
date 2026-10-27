# Phase 1: FluidAudio vs speech-swift (English ASR and Sortformer)

A small personal benchmark on the harness, run once as campaign 20261021-s2 ([results](PHASE_1_RESULTS.md),
[evidence packet](evidence/20261021-s2/README.md)). Four configurations on one frozen AMI crop:

| Row | Adapter ID | Framework (pinned source) | Model | Role |
|---|---|---|---|---|
| D1 | `fluid-sortformer-v21-lowctx` | FluidAudio `61d41b3c…` | Sortformer v2.1 streaming, `fastV2_1` (C6/L1/R7, FIFO 40, cache 188) | diarization |
| D2 | `speech-sortformer-v21-streaming` | speech-swift `3f58a58a…` | Sortformer v2.1, `.streaming` preset (same geometry) | diarization |
| A1 | `fluid-parakeet-eou-120m-320ms` | FluidAudio | Parakeet EOU 120M, 320 ms conversion | ASR |
| A2 | `speech-parakeet-eou-120m-int8` | speech-swift | Parakeet EOU 120M, INT8 conversion | ASR |

Each run loads one model in a fresh process (one active role); the other role is a passive adapter
(`passive-asr` / `passive-diar`) that loads nothing and emits nothing. Pairs are **best-practical**
comparisons: the conversions, precision and post-processing differ (see `PHASE_1_RESULTS.md`).

## What the wrappers emit

- **Diarization (final-only).** Audio feeds the native streaming state during `consume`; nothing is
  emitted until `flush`, which finalizes once and emits the complete final timeline as immutable
  `speaker.segment` events with `.flush` cause. Fluid's timeline is read from the retained finalized
  segments (the `finalizeSession()` return value is only a delta); speech-swift's comes from `finish()`.
  Boundaries are quantized to half-open 16 kHz samples (Fluid frames exactly, speech seconds to the
  nearest sample), only declared end-of-stream padding (≤ 2 frames) is clipped, different-speaker
  overlap is kept, same-speaker overlaps are merged, and the emitted union is checked against the
  native union. Online speaker-label latency is therefore **not computable** by design.
- **ASR (recording granularity).** Genuine partials of one recording utterance (`recording`) with
  increasing revisions, then exactly one final at flush, all with `media: null`. Fluid partials are
  its cumulative callback text (drained from a bounded mailbox after each awaited call; `process`
  returns empty text by design, `finish()` returns the transcript). speech-swift partials/finals are
  segment-indexed; finalized segments are kept (repeats preserved, no substring deduplication) and the
  open partial is replaced. No word timestamps exist, so time-to-first-word is not computable.
  The wrapper can only keep what the SDK emits: speech-swift's native session itself drops a final
  equal to the previous final, discards a final confirmed in `finalize()`'s trailing chunk, and does
  not decode audio after that chunk (`Tests/SpeechNativeEOUTests`; impact on the 20261021-s2 runs in
  `PHASE_1_FOLLOWUP_RESULTS.md`). A superseded open partial is therefore dropped from the final.

## Before you start

This guide is for reproducing or extending the real-model campaign. The default build and the
[README quick start](../../README.md#quick-start-mock-adapters) use only mocks, and you do not need
anything here to try the harness.

| Stage | What it needs | What it proves |
|---|---|---|
| 1. Assets | Your own lawful copies of 4 model conversions (~800 MB) and AMI ES2008a/ES2008b headset mixes plus manual annotations 1.6.2 (~23 MB zip). Network for the downloads | Nothing yet. Check the hashes with `scripts/check_phase1_assets.py` |
| 2. Optional SDK build | Network for SwiftPM and GitHub, macOS 15+, ~4.3 GB `.build`, a separate checkout | That the wrappers compile. Stub tests check contracts, **not** recognition |
| 3. Smoke and negative controls | Stages 1–2 and `/usr/bin/sandbox-exec` | That each real model loads offline and produces valid output on 60 s, and that empty assets fail at `prepare` |
| 4. Measured campaign | Stage 3, and several hours of an otherwise idle machine | New measurements on **your** host. They are a new campaign, not the historical one |

Nothing is downloaded, accepted or run automatically. Rows whose prerequisites are missing are
recorded as `blocked` with a reason, and the other rows continue. A blocked or `NOT_RUN` result is
not a reproduction.

## 1. Assets and licenses

Read each model card and license **at the pinned revision** before downloading. Each conversion
carries the original NVIDIA checkpoint terms plus the conversion repository's terms
([THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md#models-never-committed)). AMI is CC BY 4.0
(<https://groups.inf.ed.ac.uk/ami/corpus/license.shtml>). Do not commit any of these files.

| Row | Repository @ revision | Files to place under `root` | Size |
|---|---|---|---:|
| D1 | `FluidInference/diar-streaming-sortformer-coreml` @ `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1` | `v3/fp16/Sortformer_v2.1.mlmodelc/**` (repository paths kept) | 240.6 MB |
| D2 | `aufklarer/Sortformer-Diarization-CoreML` @ `47707a55d23633d3947f168a46ad46960a8639b9` | `Sortformer_streaming.mlmodelc/**` and `config.json`, inside a directory named `aufklarer-Sortformer-Diarization-CoreML/` | 236.1 MB |
| A1 | `FluidInference/parakeet-realtime-eou-120m-coreml` @ `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355` | `320ms/{streaming_encoder,decoder,joint_decision}.mlmodelc/**` and `320ms/vocab.json` | 224.2 MB |
| A2 | `aufklarer/Parakeet-EOU-120M-CoreML-INT8` @ `fca97346c39ef8cc046e7b13515972f6db48e2ee` | `{encoder,decoder,joint}.mlmodelc/**`, `vocab.json` and `config.json`, inside `aufklarer-Parakeet-EOU-120M-CoreML-INT8/` | 118.1 MB |

The authoritative selection is the per-file list (path relative to `root`, bytes, SHA-256) in
[`evidence/20261021-s2/provenance.json`](evidence/20261021-s2/provenance.json) → `profiles`. After
you place the files, check them:

```sh
.venv/bin/python scripts/check_phase1_assets.py \
    docs/phase1/evidence/20261021-s2/provenance.json "$INPUTS"
```

Use any download client you trust, in its **own** environment. Do not install it into `.venv`: the
analysis doctor fails if a hub client such as `huggingface-hub` is installed there. Pass the full
revision, never a branch name. The client invocation is not prescribed here because it was not run
during this publication work.

AMI: download `ES2008a.Mix-Headset.wav` and `ES2008b.Mix-Headset.wav` (the separate 60 s smoke item)
and `ami_public_manual_1.6.2.zip` from <https://groups.inf.ed.ac.uk/ami/download/>. Keep the official
layout: `<audio_root>/<meeting>/audio/<meeting>.Mix-Headset.wav` and
`<annotations_root>/{corpusResources/meetings.xml,words/<meeting>.<agent>.words.xml}`. The historical
source audio SHA-256 values are in `provenance.json` → `dataset`.

### The inputs file

Copy [`phase1-inputs.example.json`](phase1-inputs.example.json) to a **private** location outside the
repository, or to the git-ignored `phase1-inputs.json` at the repository root. Then edit it:

- Set every `root`, `audio_root` and `annotations_root` to an absolute path.
- Only after you have read and accepted the terms yourself, set each `license_acceptance` to
  `{"accepted": true, "evidence": "<where and when you accepted>"}` and fill in `license_evidence`
  for AMI. The example ships with `accepted: false`, which blocks every row with
  "no recorded owner acceptance".
- `owner_authorization` and `acquisition` are recorded for provenance. They are not permissions
  that the scripts grant.

The campaign records only the SHA-256 of this file, but never publish the file itself.

## 2. Optional SDK build

Use a separate clone, because the optional graphs rewrite `Package.resolved`:

```sh
export PYTHONPATH="$PWD/analysis/src" MPLBACKEND=Agg PYTHONDONTWRITEBYTECODE=1
bash scripts/setup.sh --skip-build
.venv/bin/python scripts/run_phase1.py vendor-speech      # fresh speech-swift 3f58a58a + owned patch into vendor/
.venv/bin/python scripts/run_phase1.py verify-speech      # read-only: HEAD, diff == patch bytes, two files
cp docs/phase1/evidence/20261021-s2/Package.resolved.both Package.resolved   # the campaign's 41-pin lock
PHASE1_FRAMEWORKS=both swift build --disable-keychain -c release --scratch-path .build/phase1-both
.build/phase1-both/release/voicebench --version
# 0.7.0-phase0 (schema 1.0; phase1 frameworks: FluidAudio@61d41b3ca048, speech-swift@3f58a58a8f86)
```

`PHASE1_FRAMEWORKS` is `none` (the default, mock-only), `fluid`, `speech` or `both`. FluidAudio is
used only with its `Diarizer` trait. Its prebuilt NeMo text-normalization artifact is downloaded at
resolution but never linked. speech-swift is used from `vendor/speech-swift`: the pinned commit plus
`patches/speech-swift-3f58a58a-phase1.patch`, which changes two files. The first is a manifest
rename of its benchmark-only `BenchmarkSupport` target, which collides with the harness module. The
second adds optional `cacheDir:`/`offlineMode:` parameters to the EOU loader. The copy contributes
only `SpeechVAD`, `ParakeetStreamingASR` and `AudioCommon`. MLX is a compile-time dependency of
`SpeechVAD`, not evidence of GPU inference. Because `Package.resolved` cannot pin a path dependency,
`verify-speech` is how the speech-swift source is authenticated. Older copies carry a
`PHASE1_VENDOR.json` that names an obsolete one-file patch. `verify-speech` reports that record and
does not trust it.

A source rebuild is a **new binary identity**. On 2026-10-27, a rebuild of the publication branch with
this lock and patch produced SHA-256 `a1b5303c…`, not the campaign's `5f8ccfe3…`. Exact historical
binary reproduction is not claimed.

Model-free tests for this build:

```sh
VB="$PWD/.build/phase1-both/release/voicebench"
VOICEBENCH_BIN="$VB" PHASE1_FRAMEWORKS=both bash scripts/swift_test.sh --disable-keychain --scratch-path .build/phase1-both
VOICEBENCH_BIN="$VB" .venv/bin/python -m pytest analysis/tests -q
```

`RealAdapterTests` run fake backends behind the same wrappers, including runs through the unchanged
runner and scorer. `SpeechNativeEOUTests` (speech builds only) drive the unmodified speech-swift EOU
session with stub models and scripted token/EOU outputs, and `withKnownIssue` marks the native loss
cases they document. Results on 2026-10-27: 220 Swift tests passed with 5 known issues, and 289
Python tests passed. These tests prove wrapper contracts, not recognition quality.

## 3. Prepare data, smoke and negative controls

`SESSION` must be a new directory. Every stage refuses an existing output.

```sh
INPUTS="/ABSOLUTE/PATH/phase1-inputs.json"
SESSION="$PWD/evidence/phase1/one-shot/$(date +%Y%m%d)-mine"
VB="$PWD/.build/phase1-both/release/voicebench"
.venv/bin/python scripts/run_phase1.py snapshot --out "$SESSION/snapshot-start.json"
.venv/bin/python scripts/prepare_phase1_data.py --inputs "$INPUTS" --voicebench "$VB" --out "$SESSION/datasets"
.venv/bin/python scripts/run_phase1.py campaign --inputs "$INPUTS" --datasets "$SESSION/datasets" \
    --voicebench "$VB" --out "$SESSION/preflight" --skip-measured
```

- **Dataset stage:** the ES2008a headset mix (or the lexically first eligible meeting in your
  inventory), cropped to a 900–1200 s prefix whose end cuts no word. It writes a recording-text
  reference and a derived word-union speaker reference, transcript-only and speaker-only manifests
  over identical audio, and a 60 s smoke item from `smoke_meeting`. It then runs
  `validate --dataset --require-ready` and the automatic RMS alignment spot check. The spot check
  is uncalibrated: a pass or fail does not settle alignment, which needs a human listening check.
  Exit code 3 with `blocked` means an input is missing, and the reason names it.
- **`--skip-measured`:** freezes the profiles (`p1:<sha256>` revisions) and runs the deny-network
  sandbox controls. It then runs, per row, a network-denied 60 s smoke and an empty-assets negative
  control (which must fail at `prepare`), and one 60 s mock pacing check.

The campaign sets `VOICEBENCH_PHASE1_PROFILES`, `VOICEBENCH_PHASE1_ASSETS` and
`SPEECH_COREML_COMPUTE_UNITS=all` (the speech-swift EOU loader otherwise hard-codes `.cpuAndGPU`).
It removes `FLUID_EOU_FUSED`, `QWEN3_CACHE_DIR` and `QWEN3_ASR_CACHE_DIR`. Both speech-swift loaders
run with an explicit cache directory and `offlineMode: true`, and the sandbox is a second guarantee.
`sandbox-exec` is deprecated by Apple but worked on macOS 26.6.2.

## 4. Measured campaign

```sh
.venv/bin/python scripts/run_phase1.py campaign --inputs "$INPUTS" --datasets "$SESSION/datasets" \
    --voicebench "$VB" --out "$SESSION/campaign"           # add --binary speech=PATH for separate builds
.venv/bin/python scripts/run_phase1.py verify --snapshot "$SESSION/snapshot-start.json" --out "$SESSION/snapshot-end.json"
.venv/bin/python scripts/report_phase1.py --campaign "$SESSION/campaign" --datasets "$SESSION/datasets" \
    --protected "$SESSION/snapshot-end.json" --out "$SESSION/report"
```

The campaign runs three fresh-process repetitions per row in F/S, S/F, F/S order, with a 60 s
cooldown. Each run times out at `3 × duration + 10 min`. It warns at 8 GiB RSS and stops at 10 GiB
or critical memory pressure. A failed run gets one unchanged retry. Every run is followed by
`validate --run` and an entry in the append-only `ledger.jsonl`. With the 1,039.88 s crop, 12 paced
runs plus cooldowns took about 4.5 hours on the historical host (02:25–06:57).
Keep the tree clean during the campaign: two historical runs record a dirty working tree
([evidence README](evidence/20261021-s2/README.md#runs)). The report gives each row a status of
COMPLETE, PARTIAL, NOT_RUN or INVALID, together with `results-per-run.csv`, median [min, max]
summaries and plots. COMPLETE describes execution only. Accuracy stays conditional until the
references have been checked by a human.

Read-only follow-up audits of saved runs live in `scripts/phase1_followup/`. Each writes one new
file and refuses to overwrite:

- `asr_rollback_audit.py` checks for vanished open text and for a final that differs from the last partial.
- `memory_reanalysis.py` recomputes memory over uniform windows.
- `der_shift_sensitivity.py` is diagnostic only.
