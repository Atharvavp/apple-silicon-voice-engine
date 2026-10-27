# Phase 1: FluidAudio vs speech-swift (English ASR and Sortformer)

A small personal benchmark on the Phase 0 harness. Four configurations on one frozen AMI crop:

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

## Build

```sh
export PYTHONPATH="$PWD/analysis/src" MPLBACKEND=Agg PYTHONDONTWRITEBYTECODE=1
# DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # only if the owner installed Xcode
.venv/bin/python scripts/run_phase1.py vendor-speech   # owned speech-swift copy + manifest patch (DEC-079)
PHASE1_FRAMEWORKS=both swift build --disable-keychain -c release --scratch-path .build/phase1-both
.build/phase1-both/release/voicebench --version   # lists the compiled frameworks
```

`PHASE1_FRAMEWORKS` is `none` (default: the Phase 0 mock-only graph), `fluid`, `speech` or `both`.
SwiftPM rewrites `Package.resolved` for the selected graph; the committed file is the `both` lock and
each variant's lock is copied into the evidence packet. FluidAudio is used with only its `Diarizer`
trait (its prebuilt NeMo text-normalization artifact is still downloaded at resolution, never linked).
speech-swift is used from `vendor/speech-swift`: the pinned commit plus `patches/speech-swift-3f58a58a-phase1.patch`
(two files: a manifest rename of its benchmark-only `BenchmarkSupport` target, which collides with the
harness module, and optional `cacheDir:`/`offlineMode:` parameters on the EOU loader). It
contributes only `SpeechVAD`, `ParakeetStreamingASR` and `AudioCommon`; MLX is a
compile-time dependency of `SpeechVAD`, not evidence of GPU inference.

## Owner inputs (`phase1-inputs.json`)

Nothing is acquired or accepted on the owner's behalf. The campaign reads one local file:

```json
{
  "inputs_version": 1,
  "owner_authorization": {"statement": "…", "date": "YYYY-MM-DD"},
  "developer_dir": null,
  "acquisition": {"mode": "local-only", "allowed_sources": [], "max_download_bytes": 0},
  "models": {
    "fluid-sortformer-v21-lowctx": {
      "root": "/abs/models/fluid-sortformer", "repository": "FluidInference/diar-streaming-sortformer-coreml",
      "revision": "<40-hex commit>", "load_path": "v3/fp16/Sortformer_v2.1.mlmodelc",
      "precision": "fp16", "licenses": ["NVIDIA Open Model License", "<conversion terms>"],
      "license_acceptance": {"accepted": true, "evidence": "<where/when the owner accepted>"}
    },
    "speech-sortformer-v21-streaming": {"root": "/abs/models/speech-sortformer", "load_path": "<dir with Sortformer_streaming.mlmodelc and config.json>", "…": "…"},
    "fluid-parakeet-eou-120m-320ms": {"root": "/abs/models/fluid-eou", "load_path": "<dir with streaming_encoder/decoder/joint_decision .mlmodelc and vocab.json>", "…": "…"},
    "speech-parakeet-eou-120m-int8": {"root": "/abs/models/speech-eou", "load_path": "<dir with encoder/decoder/joint .mlmodelc, vocab.json and config.json>", "…": "…"}
  },
  "datasets": {
    "ami": {
      "audio_root": "/abs/amicorpus", "annotations_root": "/abs/ami_public_manual_1.6.2",
      "annotations_version": "1.6.2", "source_url": "https://groups.inf.ed.ac.uk/ami/download/",
      "license": "CC-BY-4.0", "license_evidence": "<owner note>", "redistribution_allowed": null,
      "meeting_inventory": ["ES2008a"]
    },
    "voxconverse": null
  }
}
```

`audio_root/<meeting>/audio/<meeting>.Mix-Headset.wav` and `annotations_root/{corpusResources/meetings.xml,
words/<meeting>.<agent>.words.xml}` follow the official AMI layout. Fluid's Sortformer row loads the
compiled BNNS-fixed `v3/fp16` export (FluidAudio's own `fastV2_1`/fp16 mapping); the wrapper rejects
a model whose embedded geometry differs from the profile.

## Run the stages

`SESSION` is a new directory under `evidence/phase1/one-shot/`; every script refuses an existing output.

```sh
VB=.build/phase1-both/release/voicebench
.venv/bin/python scripts/run_phase1.py snapshot --out "$SESSION/snapshot-start.json"
.venv/bin/python scripts/prepare_phase1_data.py --inputs "$INPUTS" --voicebench $VB --out "$SESSION/datasets"
.venv/bin/python scripts/run_phase1.py campaign --inputs "$INPUTS" --datasets "$SESSION/datasets" \
    --voicebench $VB --out "$SESSION/campaign"          # add --binary speech=PATH for a separate build
.venv/bin/python scripts/run_phase1.py verify --snapshot "$SESSION/snapshot-start.json" --out "$SESSION/snapshot-end.json"
.venv/bin/python scripts/report_phase1.py --campaign "$SESSION/campaign" --datasets "$SESSION/datasets" \
    --protected "$SESSION/snapshot-end.json" --out "$SESSION/report"
```

- **Dataset stage:** ES2008a headset mix (or the lexically first eligible meeting of the approved
  inventory), prefix of 900–1200 s whose end cuts no word; recording-text and derived word-union
  speaker references; transcript-only and speaker-only manifests over identical audio; a disjoint
  60 s smoke item; `validate --dataset --require-ready`; an automatic RMS alignment spot check.
- **Campaign:** profiles hashed into `p1:<sha256>` revisions; deny-network sandbox controls; per row a
  network-denied 60 s smoke plus an empty-assets negative control (must fail at prepare); frozen
  `matrix.json`; three fresh-process repetitions per row in F/S, S/F, F/S order, 60 s cooldown,
  timeout `3 × duration + 10 min`, RSS warning at 8 GiB and stop at 10 GiB or critical memory pressure,
  one unchanged retry, `validate --run` per run, an append-only `ledger.jsonl`; one 60 s mock pacing
  check per binary.
- **Report:** eligibility checks, `results-per-run.csv`, median [min, max] summaries, up to three
  plots and `PHASE_1_RESULTS.md` with status COMPLETE / PARTIAL / NOT_RUN / INVALID.

Runtime environment set by the campaign: `VOICEBENCH_PHASE1_PROFILES`, `VOICEBENCH_PHASE1_ASSETS`,
`SPEECH_COREML_COMPUTE_UNITS=all` (the speech-swift EOU loader otherwise hard-codes `.cpuAndGPU`);
`FLUID_EOU_FUSED`, `QWEN3_CACHE_DIR` and `QWEN3_ASR_CACHE_DIR` are removed. Both speech-swift loaders
run with an explicit cache directory and `offlineMode: true` (the EOU loader's parameters come from the
owned copy's patch, DEC-079), so neither contacts the Hub; the sandbox is a second guarantee.

## Tests

```sh
VB=$PWD/.build/phase1-both/release/voicebench
VOICEBENCH_BIN=$VB PHASE1_FRAMEWORKS=both scripts/swift_test.sh --scratch-path .build/phase1-both
VOICEBENCH_BIN=$VB .venv/bin/python -m pytest analysis/tests -q
```

`RealAdapterTests` are model-free (fake backends behind the same wrappers, including runs through
the unchanged runner and scorer). They prove wrapper contracts, not recognition quality; the model
rows are proven only by the campaign's smokes and measured runs. `SpeechNativeEOUTests` (speech
builds only) run the unmodified speech-swift EOU session against stub models with scripted
token/EOU outputs; `withKnownIssue` marks the native loss cases they document.

Read-only follow-up audits of saved runs live in `scripts/phase1_followup/` (each writes one new
file and refuses to overwrite): `asr_rollback_audit.py` (vanished open text / final-vs-last-partial),
`memory_reanalysis.py` (uniform memory windows) and `der_shift_sensitivity.py` (diagnostic only).
