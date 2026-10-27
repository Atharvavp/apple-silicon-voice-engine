# Evidence packet: Phase 1 campaign 20261021-s2

This is a small public index of the historical real-model campaign that the corrected
[Phase 1 results](../../PHASE_1_RESULTS.md) describe. It holds aggregate results, the identities of
every input, and the per-run execution record. The original session directory
(`evidence/phase1/one-shot/20261021-s2/`, about 2.4 GB) stays private and unchanged. It contains
the cropped AMI audio, the reference transcript, full event and telemetry traces, and local paths.

**This is not a reproduction bundle.** It lets you check identities, read the measured values, and
see how each summary row was reduced from per-run values. It does not let you recompute WER, CER,
DER or JER from raw outputs, because predictions, references and audio are omitted (below).

## Files

| File | What it is | SHA-256 |
|---|---|---|
| `results-per-run.csv` | Per-run metrics for the 12 measured runs: accuracy, timing, sampled memory and CPU, ledger fields. Byte-identical copy of the session's `report/results-per-run.csv` | `51c3b9a0…6599` |
| `results-summary.csv` | Median [min, max] (n) per row across the three repetitions. Byte-identical copy of `report/results-summary.csv` | `e07bb66a…a7b6` |
| `report.json` | Report generator output: status, summaries, pair classification. Byte-identical copy of `report/report.json` | `d99f908b…f56c` |
| `Package.resolved.both` | The exact 41-pin SwiftPM lock of the campaign binary. Byte-identical copy of `build/Package.resolved.both` | `aee60879…2a3f` |
| `provenance.json` | Identities and execution record, built read-only from the session by [`scripts/export_evidence_packet.py`](../../../../scripts/export_evidence_packet.py). New file, not a copy of any sealed artifact | see `MANIFEST.sha256` |
| `recomputation.json` | Result of re-deriving the summaries and re-reading per-run accuracy (below) | see `MANIFEST.sha256` |
| `MANIFEST.sha256` | SHA-256 of every file above except this README | — |

The full hashes are in `MANIFEST.sha256`. `recomputation.json` maps each copy to its original path
and hash. The figures from the generated report (`accuracy.png`, `service_time.png`, `memory.png`)
are left out on purpose. They are bare per-row bars without the caveats below, and they invite a
framework ranking that this data does not support.

## What was measured

| | |
|---|---|
| Campaign | 2026-10-21 02:25–06:57 +0530. Status `measured`, generated report `COMPLETE` (execution only) |
| Matrix | 4 configurations × 3 fresh-process repetitions = 12 measured runs, order F/S, S/F, F/S, 60 s cooldown |
| Role per run | **One** active model role (ASR **or** diarization) plus a passive counterpart that loads nothing. No run executed ASR and diarization models together |
| Replay | Realtime 1× paced, 20 ms (320-sample) frames, queue capacity 32, block on overflow, telemetry 1 s |
| Input | AMI ES2008a headset mix, first 1,039.88 s = 16,638,080 samples, 16 kHz mono, byte-exact prefix (no resampling) |
| Network | Every measured run ran under a deny-network sandbox (`sandbox_denial_enforced: true`) |
| Host | Apple M5 (`Mac17,3`), 17,179,869,184 bytes memory, 10 logical CPUs, macOS 26.6.2 (25G83), arm64, on AC power. One machine: this is not a platform-compatibility result |
| Toolchain | Swift 6.3.x, SDK 26.5, deployment target 15.0, release build. Analysis Python 3.12.14, runtime lock `75301ec0…25f5` |

## Identities

| Item | Identity |
|---|---|
| Campaign binary | SHA-256 `5f8ccfe372b246d2e64b75b23b87706ae94c7c1c71adf2ebbe3c0247261931c8`, `0.7.0-phase0 (schema 1.0; phase1 frameworks: FluidAudio@61d41b3ca048, speech-swift@3f58a58a8f86)`. The same binary for all rows |
| Source | git `e29f345abbdaa68cd496955b5e00f3fed86b140d` (see the dirty-tree note below) |
| SwiftPM lock | `aee60879806d3b495c2794a43743114016a2803e8053d97fc350fc83644c2a3f` (`Package.resolved.both`) |
| Schema bundle | `cc647ac939b23f7721b5ca739b27538c3701702c7c691ffb3b9f2560a8918407` (frozen v1, 14 files). Protected inputs comparison: pass |
| FluidAudio | `61d41b3ca04833d1cb80632c82ba401f117a01ef` (Diarizer trait) |
| speech-swift | `3f58a58a8f867a4c87b97dbf4d6050d6a88ef665` plus `patches/speech-swift-3f58a58a-phase1.patch` (SHA-256 `1984bb57…73d9`, two files) |
| Dataset freeze | `6c22d6519ce5b7b11f62280386ec8db70bad85612ff429245c275748c7977f28` |
| AMI source audio | `ES2008a.Mix-Headset.wav` SHA-256 `65fcfc924e9bdb0388cbc3242a17bda88291ebc638f486e39a9ede78e92cb1e6` (16,693,760 frames) |
| Evaluation crop | `ami-ES2008a-mixheadset-0-16638080` SHA-256 `81d6207a9a957b380423fcb5cbe010fe035ddbe5de8f59aecea9d55119bc91b0` |
| Transcript reference | `ami_nxt_recording_text_v1`, 2,496 words, SHA-256 `db53b4399b4c9b50f03c5421798fed0de204743d6d7e2e2a4fba56b36631c98a` |
| Speaker reference | `derived_word_union_v1`, 167 segments, 4 speakers, SHA-256 `c2becd260b79342071cbb746e871294ce94ad12ad1e6271625f5fbc4e91eb318` |
| Annotations | AMI manual annotations 1.6.2. `meetings.xml` and per-speaker `words` file hashes are in `provenance.json` |

| Row | Adapter | Profile revision | Model repository @ revision | Selected files |
|---|---|---|---|---|
| D1 | `fluid-sortformer-v21-lowctx` | `p1:d6976b6c…09b3` | `FluidInference/diar-streaming-sortformer-coreml` @ `ae9a27ab45dc…` (`v3/fp16/Sortformer_v2.1.mlmodelc`) | 10 files, 240,559,362 bytes |
| D2 | `speech-sortformer-v21-streaming` | `p1:9121de75…4e53` | `aufklarer/Sortformer-Diarization-CoreML` @ `47707a55d236…` | 12 files, 236,094,484 bytes |
| A1 | `fluid-parakeet-eou-120m-320ms` | `p1:91f0a31a…2287` | `FluidInference/parakeet-realtime-eou-120m-coreml` @ `40a23f4c0b33…` (`320ms/`) | 16 files, 224,238,270 bytes |
| A2 | `speech-parakeet-eou-120m-int8` | `p1:9aa209ac…68f8` | `aufklarer/Parakeet-EOU-120M-CoreML-INT8` @ `fca97346c39e…` | 14 files, 118,097,523 bytes |

`provenance.json` lists every selected model file with its path, byte count and SHA-256, the full
40-character revisions, settings, declared licenses and requested compute units (`all` for every
row; observed placement is unavailable).

## Runs

All 12 runs finished `completed`. Each has supervisor exit 0, `validate --run` exit 0, initial and derived
validation `pass`, 16,638,080 samples produced, admitted and consumed, 0 dropped, no data loss, not
mock, network denied, no retry and no supervisor stop. Each (row, repetition) pair appears exactly once.

| Run | Started (+0530) | Supervisor elapsed s | Source tree at run start |
|---|---|---:|---|
| D1-rep1 / D2-rep1 | 02:30 / 02:52 | 1144.4 / 1144.3 | clean |
| A1-rep1 / A2-rep1 | 03:14 / 03:35 | 1144.2 / 1148.3 | clean |
| D2-rep2 / D1-rep2 | 03:57 / 04:19 | 1144.2 / 1144.1 | clean |
| A2-rep2 / A1-rep2 | 04:40 / 05:02 | 1148.4 / 1146.3 | clean |
| D1-rep3 / D2-rep3 | 05:24 / 05:46 | 1145.7 / 1146.5 | clean |
| A1-rep3 / A2-rep3 | 06:07 / 06:32 | 1244.9 / 1243.2 | **`git_dirty: true`** |

**Dirty-tree note (found while building this packet, 2026-10-27).** A1-rep3 and A2-rep3 record
`git_dirty: true` in their sealed `config.json` and `environment.json`. The working tree changed
between 05:46 and 06:07, while the campaign was running. The protected-input comparison (schemas,
scoring, harness core sources, configs, datasets) passed, and the `Package.resolved` hash is unchanged.
The binary was hashed once, when the campaign started, and not again for each run. The ~100 s
longer supervisor wall time of these two runs covers the whole `voicebench run` process (including
its own scoring and sealing), not only replay, and its cause was not investigated. Their prediction content is byte-identical to
repetitions 1 and 2 of the same row. The earlier statement that "the measured run configs record
clean `e29f345`" is true for 10 of 12 runs.

**Commit identifiers after the 2026-10-28 attribution cleanup.** This packet and the sealed run
artifacts record source revision `e29f345abbdaa68cd496955b5e00f3fed86b140d`. Before publication,
commit messages were rewritten to remove an automated co-author trailer. Only messages changed, so
every file tree is identical, but the commit IDs differ. In the published history, the same tree
(`d7b259367586a9ed9855e3978debabe3cb1834d0`) is commit `873e5df01c77f40cfca26853f9e21251ccb9dab8`.
The snapshot's `head_before` `da04cd2…` is published as `8fc46d0…`. The recorded values are left
unchanged, because they are what the campaign saw.

Smoke, negative-control and pacing checks (`provenance.json` → `checks`): one 60 s network-denied
smoke and one empty-assets negative control per row (all pass; each negative control exits 5 at prepare
as intended), plus one 60 s mock pacing run (pass).

## Reading the numbers

The caveats in the [results](../../PHASE_1_RESULTS.md) apply to every value here:

- **Accuracy is conditional.** The automatic RMS alignment spot check failed its uncalibrated 1.5
  threshold (ratios 1.203 / 1.831 / 1.286), and no manual listening check has been recorded. The
  references are this project's own projections of the AMI manual annotations. They are not
  comparable with published AMI WER or DER. Both model families list AMI in their training data.
- **Repetitions show determinism, not variance.** Prediction content is identical across the three
  repetitions of each row.
- **Timing.** `adapter_service_rtf` is accumulated `consume`/`flush` wall time divided by audio
  duration during 1× paced replay. Its inverse is **not** throughput or "x faster than real time".
  Saturated throughput was not measured.
- **ASR text** is recording-level and untimed (no word timestamps, no first-word or EOU latency).
  **Diarization** emits its timeline once, at flush (no online speaker-label latency).
- **Memory and CPU** are samples of the runner process (about 1 Hz). They are not model-only memory,
  total unified memory or a process-tree peak. The supervisor column observes one PID over a
  longer window. GPU, ANE, power and thermal behavior were not measured.
- **Rows differ in more than framework**: conversion, precision, post-processing, native decoding
  (A2 has documented native finalization limits) and compute-unit handling. Pairs are
  `best_practical`. Do not rank frameworks or quantization schemes from these values.

## What is omitted, and why that limits recomputation

| Omitted | Reason | Consequence |
|---|---|---|
| Crop and smoke WAVs, the AMI source audio | AMI audio is CC BY 4.0, but redistribution was not part of the approved scope | Model outputs cannot be regenerated from this packet. Obtain AMI yourself and check the hashes above |
| Reference transcript and speaker JSON | They contain AMI transcript text | WER/CER/DER/JER cannot be recomputed here. The reference hashes let you confirm a locally rebuilt reference |
| `predictions.json`, `events.jsonl`, `telemetry.jsonl`, `metrics.json` | Transcript text, large traces (`events.jsonl` alone is ~187 MB for one ASR run), absolute local paths | Timing and memory reductions can be checked only at the per-run aggregate level. Sealed hashes are listed per run |
| Owner inputs file, license-acceptance notes, model weights | Private, and models are not redistributable under this scope | Supply your own lawfully obtained assets ([optional real-model guide](../../README.md)) |

## How this packet was produced and checked

```sh
.venv/bin/python scripts/export_evidence_packet.py \
    --session evidence/phase1/one-shot/20261021-s2 --out docs/phase1/evidence/20261021-s2
```

The exporter writes only into a new directory and reads the session without modifying it. A
SHA-256 listing of all 623 session files was identical before and after. It verifies each copy
against its original. It re-reads all 48 per-run accuracy values from the sealed `metrics.json` files
and compares them with `results-per-run.csv`. It then re-derives all 84 summary cells with the
report generator's own `summarize()`/`fmt()` and compares them with `results-summary.csv`.
Result: pass (`recomputation.json`). This reuses the project's reduction code. It is an arithmetic and
integrity check, not an independent scorer, a new inference run or a reproducible-build proof.
