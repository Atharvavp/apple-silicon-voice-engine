# Phase 1 results: FluidAudio vs speech-swift (English ASR and Sortformer)

**Execution: COMPLETE (12/12 valid runs). Accuracy validation: CONDITIONAL.**
The report generator's mechanical status is `COMPLETE` (every row has 3 eligible runs, protected inputs
unchanged). That status certifies the measurement process, not the reference data. One automatic dataset
check failed its threshold and the conditions below apply to every accuracy number.

Session 20261021-s2 (campaign 2026-10-21 02:25–06:57 +0530, verified and reported 2026-10-26).
Evidence (git-ignored): `evidence/phase1/one-shot/20261021-s2/` with the generated report in `report/` and the
review bundle in `review-package/`. Campaign evidence was only read; the report went to a new `report/` directory.
Hardware: Apple M5 (Mac17,3), macOS 26.6.2, on AC power. The plan assumes a fanless MacBook Air with 16 GB; memory size was not re-verified here.
Code: `e29f345` plus the uncommitted `scripts/report_phase1.py` reporting changes (the generated report therefore
says "dirty"); the campaign binary is SHA-256 `5f8ccfe3…1c8` (FluidAudio `61d41b3c`, speech-swift `3f58a58a`).

## History

| Session | Outcome | Record |
|---|---|---|
| 20261021-s1 | `NOT_RUN`: implementation, builds and model-free tests only; no model or AMI data existed | `docs/phase1/history/PHASE_1_RESULTS-20261021-s1-NOT_RUN.md` |
| 20261021-s2 | Real-model campaign executed; 12/12 valid | this document |

The s1 build, test and integration findings (owned speech-swift copy DEC-079, keychain stalls, API differences)
remain accurate and are kept in the history file.

## Verification of execution

Independently re-checked from the ledger, per-run status, sealed validation and metrics (see
`review-package/campaign-validation-summary.md`). For all 12 measured runs: state `completed`, supervisor exit 0,
`validate --run` exit 0 and `pass`, 0 dropped samples, 16,638,080 of 16,638,080 samples consumed, not mock,
network denied, `predictions.json` hash matches metrics, no retries, no supervisor stop. The 4 smoke runs, 4
empty-asset negative controls and the 60 s mock pacing run also passed. Protected inputs: pass.

## Setup

One AMI meeting, ES2008a headset mix, first 1039.88 s (16,638,080 samples, 16 kHz mono, byte-exact crop). One
active model per run with a passive counterpart role, fresh process, real-time 1x replay, 20 ms frames, queue 32,
block on overflow, 60 s cooldown, runs ordered F/S, S/F, F/S per repetition. Core ML compute units requested:
`all` for all four rows; observed placement is unavailable.

| Row | Framework | Model | Repository (selected files) | Precision | Compute units |
|---|---|---|---|---|---|
| D1 | FluidAudio | Sortformer v2.1 low-context | FluidInference/diar-streaming-sortformer-coreml `v3/fp16` | FP16 BNNS-fixed export | all |
| D2 | speech-swift | Sortformer v2.1 streaming | aufklarer/Sortformer-Diarization-CoreML | FP16 compute, FP32 I/O (model card) | all |
| A1 | FluidAudio | Parakeet EOU 120M, 320 ms | FluidInference/parakeet-realtime-eou-120m-coreml | FP16 storage | all |
| A2 | speech-swift | Parakeet EOU 120M | aufklarer/Parakeet-EOU-120M-CoreML-INT8 | INT8-palettized encoder | all (`SPEECH_COREML_COMPUTE_UNITS=all`; the loader otherwise hard-codes `.cpuAndGPU`) |

## Results

Median across three runs. Accuracy was identical in all three repetitions of every row (prediction content is
byte-identical), so the repetitions show determinism, not variance. Fractions, not percentages.

| Row | WER | CER | DER | JER |
|---|---:|---:|---:|---:|
| D1 FluidAudio Sortformer | n/a | n/a | 0.2456 | 0.2433 |
| D2 speech-swift Sortformer | n/a | n/a | 0.2038 | 0.1989 |
| A1 FluidAudio Parakeet EOU | 0.2330 | 0.1648 | n/a | n/a |
| A2 speech-swift Parakeet EOU | 0.2379 | 0.1725 | n/a | n/a |

DER components (seconds of 805.4 s reference speech; collar 0, overlap scored):

| Row | Missed | False alarm | Confusion | Hypothesis speech s |
|---|---:|---:|---:|---:|
| D1 | 180.4 | 11.1 | 6.4 | 636.1 |
| D2 | 117.4 | 36.4 | 10.3 | 724.4 |

WER components (2682 reference words): A1 substitutions 134, deletions 451, insertions 40; A2 132 / 469 / 37.

Timing, memory and initialization (median [min, max] of three; full set including p50/p95 streaming latencies in
`results-summary.csv` and `results-per-run.csv`):

| Row | Setup s | Active processing s | Service RTF | Sampled peak RSS MiB | Sampled peak footprint MiB | CPU % one core p50 / p95 |
|---|---:|---:|---:|---:|---:|---:|
| D1 | 0.254 [0.247, 0.263] | 79.7 | 0.0767 | 526.1 | 497.0 | 6.0 / 7.0 |
| D2 | 0.247 [0.246, 0.248] | 89.7 [85.5, 89.8] | 0.0863 [0.0823, 0.0864] | 520.3 [337.3, 520.4] | 490.4 [329.5, 490.5] | 7.6 / 8.9 |
| A1 | 0.257 [0.255, 0.266] | 83.9 | 0.0807 | 712.1 | 668.8 | 9.7 / 11.4 |
| A2 | 0.179 [0.179, 0.345] | 80.7 | 0.0776 | 512.8 | 479.7 | 9.9 / 11.7 |

Service RTF is the active adapter's compute time per second of audio; all four rows run roughly 11–13x faster than
real time. Replay and end-to-end RTF are 1.00 by construction because replay is paced at 1x; they are not speed
measures. Processing lag p95 is 20–28 ms for all rows; ASR delivery-to-output p95 is about 33 ms (A1) and 29 ms (A2).
Those are wrapper timings, not word latency. Unsupported by this harness: GPU, ANE and power.

### How to read these numbers

- **DER differences are mostly speech coverage, not speaker attribution.** Confusion is 6 s (D1) and 10 s (D2) of
  805 s. D2's lower DER comes from detecting more speech (724 s vs 636 s), which cuts missed speech and raises false
  alarm. D1 and D2 apply different post-processing (below), so the DER gap is not a clean model comparison.
- **Both ASR rows are deletion-dominated** (451 and 469 of 2682 reference words, spread evenly across the thirds of the
  recording; no end-of-file truncation). The 0.005 WER gap between A1 and A2 is one deterministic run each, with no
  variance estimate; do not claim a winner.
- **Peak memory is a model-load transient.** Footprint peaks in the first seconds and falls within about 30 s
  (see D2-rep3 below). Supplementary steady-state footprint (median of the last 500 samples of run 1; computed by an
  ad-hoc analysis, not by the report generator): D1 105, D2 127, A1 329, A2 221 MiB. RSS here is the runner process,
  sampled at 1 s, not total unified memory.
- **Setup is the harness `adapter_prepare` phase (about 0.2–0.35 s).** Memory reaches its peak within the first
  samples, so first-inference or cold-cache costs are not isolated; no cold-start claim is supported.

## Validity investigation

### 1. RMS alignment spot check: failed threshold, alignment itself not contradicted (RESOLVED for DER/JER and WER/CER, with a residual limitation)

The dataset stage's automatic check (`mix_rms_speech_vs_annotated_silence_v1`) requires mean RMS in annotated speech
to exceed annotated silence by a ratio of 1.5 in each third. Measured ratios: start 1.20, middle 1.83, end 1.29, so
the start and end thirds fail. The dataset status stayed `ready`, and the check's own docstring says it is evidence
of alignment, not proof. The 1.5 threshold was never calibrated.

What the failure can and cannot mean: every ratio is above 1, so speech is louder than annotated silence everywhere
(a gross offset or inversion would flatten or flip the ratio). A headset mix sums four close-talk microphones
with room noise, laughter, breaths and cross-talk that the word-union reference counts as silence, which compresses
the ratio.

Follow-up evidence gathered here (scripts and outputs in `review-package/analysis/`):

- Earlier diagnostic (`alignment-diagnostic.json`): log-RMS envelope vs word-union activity, best lag within -0.02 to
  +0.01 s in all three thirds, so drift is about 0.02 s. Correlation at the best lag is only 0.27–0.39, which is
  modest and consistent with a noisy mix; it shows no offset, not high agreement.
- New offset sweep: I re-scored the saved predictions after shifting the reference by -5 to +5 s with the same policy
  (collar 0, overlap scored, full UEM). Shift 0 reproduces the reported DER exactly (D1 0.2456, D2 0.2038). DER rises
  steeply with any shift: D1 0.31 at -0.25 s, 0.29 at +0.25 s, 0.44 at ±1 s, 0.61 at ±5 s. D2 is minimal at 0 to +0.25
  s (0.2038 at 0, 0.1989 at +0.25) and 0.39–0.35 at ±1 s. Both independent models agree on the reference timing to
  within about a quarter second. A multi-second offset or drift would have shown up as a much higher DER.
- WER and CER are computed on recording-level text and do not use timestamps, so reference timing cannot affect them.
  The crop end was moved earlier to exclude untimed words, and both hypotheses end on the same final words as the
  reference, so there is no boundary truncation (at most the final backchannel word is missing).

Conclusion: the failed check does not invalidate the reported numbers. Residual limitation: no listening check was
performed and the reference is derived from words (below), so alignment is supported to about 0.25 s, not
to the precision of a manually segmented reference.

### 2. D2-rep3 memory anomaly (EXPLAINED, ROOT CAUSE UNRESOLVED, NO EFFECT ON RESULTS)

D2-rep3 shows sampled peak RSS 337 MiB and peak footprint 330 MiB, against 520 and 490 MiB in rep1 and rep2; the
supervisor's tree peak was 464 MB vs about 900 MB. Findings from `telemetry.jsonl`:

- All three runs show the same shape: a load transient in the first seconds, then a drop to a steady footprint
  (rep1 490 MiB at t=10 s, 117 at t=60 s; rep3 328 to 101). Steady state is similar (median 127, 129 and 117 MiB).
  What differs is the height of the load transient: rep3's was about 160 MiB lower from the first sample after load.
- Not a functional difference: DER, JER and the prediction content are identical in all three runs; setup time is
  the same (0.247 s); data integrity is clean; the sampler took the same 1042 samples.
- Not explained by recorded conditions: AC power, memory pressure level 1, thermal nominal and load average about
  1.0–1.5 were the same before every D2 run. rep3 ran last (05:46), after about 3 hours.
- Plausible, untested: Core ML model-load behaviour (compiled-model or ANE cache state, or dirty-page accounting)
  changed between launches. I did not reproduce it, and the data cannot distinguish hypotheses.

Treatment: keep rep3 (it is valid), report the range, and cite peak memory with the stated range, never as a
single exact figure. The steady-state footprint is the more stable number.

## Configuration differences that limit comparability

Classification: both pairs are `best_practical`, not matched-model.

| Aspect | FluidAudio | speech-swift |
|---|---|---|
| Sortformer export | v2.1 low-context, FP16 BNNS-fixed (`fastV2_1`) | v2.1 streaming, FP16 compute / FP32 I/O, separate conversion repo |
| Sortformer post-processing | pass-through 0.5 thresholds on a timeline | 0.3 s minimum speech, 0.15 s gap merge, speaker IDs compacted |
| Sortformer output timing | Samples | Float seconds (a frame-boundary value such as 1199.92 s can land one sample past the frame) |
| Parakeet EOU precision | FP16 storage, 320 ms chunks | INT8-palettized encoder |
| Parakeet decoding | cumulative decode via callback (`process` returns empty text) | EOU-segmented finals, consecutive identical finals suppressed |
| Compute units | `all` requested | `all` forced through an environment variable; default is `.cpuAndGPU` |
| Offline operation | sandbox denies network | explicit cache directory and `offlineMode: true` through the owned copy (DEC-079); sandbox also denies network |
| Build | same joint binary and `Package.resolved` for all rows | same |

Observed compute placement is not available for any row, so "all" is a request, not evidence that the ANE ran.

## Resolved issues and unresolved limitations

Resolved:
- All 12 runs genuinely completed and validated (re-verified).
- Alignment: no evidence of offset or drift beyond about 0.25 s (offset sweep, lag diagnostic); WER/CER are timing-independent.
- ASR deletions are not an end-of-file truncation artifact.
- Report script changes reviewed (11 campaign tests pass, compiles); the report was generated into a new directory.
- Determinism: prediction content is identical across repetitions for every row.

Unresolved (also in `review-package/unresolved-issues.md`):
1. The automatic RMS spot check failed its uncalibrated threshold; no listening check was performed.
2. One 17.3-minute meeting with four speakers; no variance across audio, and repetitions add no accuracy variance.
3. References are frozen projections: recording-text linearization (not speaker-attributed WER) and word-union speaker
   activity, which is not standard AMI segmentation and not comparable with published AMI DER or WER.
4. AMI may be in the training data of the Sortformer and Parakeet models, so this is not an unseen-holdout result.
5. D1 vs D2 and A1 vs A2 differ in conversion, precision and post-processing; differences are not attributable to the framework alone.
6. D2-rep3's lower memory peak is unexplained.
7. Setup and cold-start behaviour are not isolated; peak memory is a sampled load transient; GPU/ANE/power are unmeasured.
8. The reporting changes are uncommitted, so the generated report records a dirty tree.
9. Optional VoxConverse was skipped (no lawful audio with matching RTTMs supplied).

## Scope boundaries

Phase 1 stops here. No additional benchmarks and no Phase 2 work were started. Anything cited publicly must come from the tables
above, carry the single-meeting and best-practical caveats, and avoid ranking the frameworks.
