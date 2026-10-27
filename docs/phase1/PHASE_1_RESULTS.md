# Phase 1 results: FluidAudio vs speech-swift (English ASR and Sortformer)

**Execution: COMPLETE (12/12 valid runs). Accuracy validation: CONDITIONAL.**
The report generator's mechanical status is `COMPLETE` (every row has 3 eligible runs, protected inputs
unchanged). That status certifies the measurement process, not the reference data. One automatic dataset
check failed its threshold, the manual alignment check has not yet been performed, and the conditions below
apply to every accuracy number.

**Interpretation corrected 2026-10-26** after an [independent review](CODEX_INDEPENDENT_REVIEW.md). The
measured numbers are unchanged; several interpretations were withdrawn or narrowed. See
[Corrections](#corrections-2026-10-26) and [PHASE_1_FOLLOWUP_RESULTS.md](PHASE_1_FOLLOWUP_RESULTS.md). The
pre-review wording is preserved in `docs/phase1/history/PHASE_1_RESULTS-20261021-s2-pre-review.md`.

Session 20261021-s2 (campaign 2026-10-21 02:25–06:57 +0530, verified and reported 2026-10-26).
Evidence (git-ignored): `evidence/phase1/one-shot/20261021-s2/` with the generated report in `report/` and the
review bundle in `review-package/`. Campaign evidence was only read; the report went to a new `report/` directory.
Hardware: Apple M5 (Mac17,3), 17,179,869,184 bytes (16 GiB) memory (`sysctl hw.memsize`, recorded in all 12
run environment files), macOS 26.6.2, on AC power. Cooling/fan configuration was not measured.
Code: `e29f345` plus the uncommitted `scripts/report_phase1.py` reporting changes (the generated report therefore
says "dirty"; the measured run configs record clean `e29f345`); the campaign binary is SHA-256 `5f8ccfe3…1c8`
(FluidAudio `61d41b3c`, speech-swift `3f58a58a` plus the two-file owned patch).

## History

| Session | Outcome | Record |
|---|---|---|
| 20261021-s1 | `NOT_RUN`: implementation, builds and model-free tests only; no model or AMI data existed | `docs/phase1/history/PHASE_1_RESULTS-20261021-s1-NOT_RUN.md` |
| 20261021-s2 | Real-model campaign executed; 12/12 valid | this document (interpretation corrected 2026-10-26) |
| 20261021-s2, pre-review narrative | Superseded wording, kept for transparency | `docs/phase1/history/PHASE_1_RESULTS-20261021-s2-pre-review.md` |

The s1 build, test and integration findings (owned speech-swift copy DEC-079, keychain stalls, API differences)
remain accurate and are kept in the history file.

## Verification of execution

Independently re-checked from the ledger, per-run status, sealed validation and metrics (see
`review-package/campaign-validation-summary.md`; independently re-verified again in the review). For all 12
measured runs: state `completed`, supervisor exit 0, `validate --run` exit 0 and `pass`, 0 dropped samples,
16,638,080 of 16,638,080 samples consumed, not mock, network denied, `predictions.json` hash matches metrics, no
retries, no supervisor stop. The 4 smoke runs, 4 empty-asset negative controls and the 60 s mock pacing run also
passed. Protected inputs: pass.

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
| A2 | speech-swift | Parakeet EOU 120M | aufklarer/Parakeet-EOU-120M-CoreML-INT8 | INT8-palettized encoder storage | all (`SPEECH_COREML_COMPUTE_UNITS=all`; the loader otherwise hard-codes `.cpuAndGPU`) |

## Results

Median across three runs. Accuracy was identical in all three repetitions of every row (prediction content is
identical), so the repetitions show determinism, not variance. Fractions, not percentages. All accuracy values
use this project's own frozen reference projections (below) and are not comparable with published AMI results.

| Row | WER | CER | DER | JER |
|---|---:|---:|---:|---:|
| D1 FluidAudio Sortformer | n/a | n/a | 0.2456 | 0.2433 |
| D2 speech-swift Sortformer | n/a | n/a | 0.2038 | 0.1989 |
| A1 FluidAudio Parakeet EOU | 0.2330 | 0.1648 | n/a | n/a |
| A2 speech-swift Parakeet EOU | 0.2379 | 0.1725 | n/a | n/a |

DER components (seconds; denominator 805.38 reference **speaker**-seconds; collar 0, overlap scored, full-crop UEM):

| Row | Missed | False alarm | Confusion | Hypothesis speaker-s |
|---|---:|---:|---:|---:|
| D1 | 180.4 | 11.1 | 6.4 | 636.1 |
| D2 | 117.4 | 36.4 | 10.3 | 724.4 |

WER components (2682 normalized reference tokens): A1 substitutions 134, deletions 451, insertions 40; A2 132 / 469 / 37.

Timing, memory and prepare (median [min, max] of three; full set including p50/p95 streaming latencies in
`results-summary.csv` and `results-per-run.csv`):

| Row | Prepare s | Active adapter service s | Service RTF | Sampled peak RSS MiB | Sampled peak footprint MiB | CPU % one core p50 / p95 |
|---|---:|---:|---:|---:|---:|---:|
| D1 | 0.254 [0.247, 0.263] | 79.7 | 0.0767 | 526.1 | 497.0 | 6.0 / 7.0 |
| D2 | 0.247 [0.246, 0.248] | 89.7 [85.5, 89.8] | 0.0863 [0.0823, 0.0864] | 520.3 [337.3, 520.4] | 490.4 [329.5, 490.5] | 7.6 / 8.9 |
| A1 | 0.257 [0.255, 0.266] | 83.9 | 0.0807 | 712.1 | 668.8 | 9.7 / 11.4 |
| A2 | 0.179 [0.179, 0.345] | 80.7 | 0.0776 | 512.8 | 479.7 | 9.9 / 11.7 |

**What the timing numbers mean.** Service RTF is the accumulated wall time of the adapters' `consume` and
`flush` calls divided by audio duration. It includes awaited backend work, sample handling, transcript assembly
and synchronous sink waits; it is not compute-only time. Approximately 79–90 s of active adapter wall time
accumulated over a 1039.88 s replay paced at 1x. All four configurations sustained this separate-model 1x
workload with zero lost samples. **Maximum (saturated) throughput and compute-only time were not measured;
the inverse of service RTF is not a throughput or "x faster than real time" measurement.** Replay RTF
(1.00004–1.00011) and end-to-end RTF (1.00051–1.00089) are close to 1 because processing kept up with the paced
input; they would exceed 1 if it had not, and are not speed measures. Processing lag (chunk-consumption finish
minus that chunk's planned delivery deadline) is p95 20–28 ms; the per-run maximum is 103–259 ms, so not every
20 ms frame finished within 20 ms. ASR delivery-to-output p95 is about 33 ms (A1) and 29 ms (A2): the time from
admitting the triggering chunk to the emitted update, not word or end-of-utterance latency. Prepare is the
harness `adapter_prepare` phase (profile/asset verification plus backend load), not an isolated Core ML load or
cold start. Unsupported by this harness: GPU, ANE and power.

### How to read these numbers

- **DER differences are mostly speech coverage, not speaker attribution.** Confusion is 6 s (D1) and 10 s (D2) of
  805 speaker-seconds. D2 misses 63 fewer speaker-seconds, adds 25 false-alarm seconds and 4 confusion seconds.
  D1 and D2 apply different post-processing (below), so the DER gap is not a clean model comparison, and it does
  not establish which output is closer to a standard speech segmentation.
- **Both ASR rows are deletion-dominated** (451 and 469 of 2682 reference tokens). Deletions occur throughout the
  recording but are **not** evenly distributed: by reference-token thirds, A1 184 / 70 / 197 and A2 188 / 73 / 208.
  Token thirds are not equal-duration windows, and these counts do not diagnose why words were deleted. Late
  words are recognized, which argues against wholesale end-of-file truncation; it does not prove that no earlier
  words were omitted. The 0.005 WER gap (13 word edits) between A1 and A2 is one deterministic output each, with no
  variance estimate; do not claim a winner. A2's native session has identified transcript-loss edge cases; a
  saved-trace audit found that none of them affected these runs (validity item 3).
- **Process memory has a large early plateau, then a lower late level; its cause is not isolated.** The sampled
  footprint maximum occurs 12–20 s into the run, well after the ~0.25 s prepare phase, so it is not shown to be a
  model-load transient. Late-run footprint (median of the 500 samples before the final telemetry sample, all three
  repetitions): D1 104.7 / 136.8 / 136.8, D2 127.1 / 129.2 / 116.8, A1 328.9 / 329.0 / 329.2, A2 220.6 / 222.6 /
  222.3 MiB. D1's late level varies by about 32 MiB between repetitions. All memory figures are the runner process
  only (`resident_size` and `phys_footprint`), sampled about once per second; short peaks can be missed, and they
  are not total unified memory or a model-only allocation.

## Validity investigation

### 1. Acoustic alignment (NOT RESOLVED: DER/JER remain conditional pending the manual check)

The dataset stage's automatic check (`mix_rms_speech_vs_annotated_silence_v1`) requires the mean of per-span RMS
in annotated speech to exceed annotated silence by a ratio of 1.5 in each third. Measured ratios: start 1.20,
middle 1.83, end 1.29, so the start and end thirds fail. The dataset status stayed `ready`; that is structural
readiness, not reference validation. The 1.5 threshold was never calibrated, and the statistic (arithmetic means
over up to 40 longest spans) is not a calibrated alignment measure. A ratio above one does not rule out an offset.
A noisy four-headset mix and excluded vocalizations are plausible explanations for the low ratios, not established
causes.

Follow-up evidence (diagnostics only; the scoring reference was never shifted or tuned):

- Log-RMS envelope vs word-union activity (`alignment-diagnostic.json`): best lags −20 to +10 ms, but correlations
  are only 0.27–0.39 and the best-lag and zero-lag correlations differ by at most 0.0006. This is weak evidence
  against a gross common shift, not a bound on timing error or drift.
- DER after uniformly shifting the reference (positive = reference later; UEM fixed; speaker mapping re-optimized;
  `evidence/phase1/followup/step0/der-shift-sensitivity.json`):

  | Shift (s) | −1.00 | −0.25 | −0.16 | −0.08 | 0 | +0.08 | +0.16 | +0.25 | +1.00 |
  |---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
  | D1 DER | 0.4342 | 0.3066 | 0.2836 | 0.2632 | 0.2456 | 0.2498 | 0.2705 | 0.2947 | 0.4379 |
  | D2 DER | 0.3948 | 0.2697 | 0.2455 | 0.2239 | 0.2038 | 0.1891 | 0.1873 | 0.1989 | 0.3518 |

  DER is sensitive at the sub-second scale, and D2 *improves* by 1.65 points at +160 ms, which may reflect
  model/post-processor delay, reference boundaries, or both. This is evidence against a multi-second mismatch
  only. It does not bound alignment to 0.25 s: minimum DER against model output is not ground truth, and the two
  diarizers are ports of the same model family, not independent references.
- Recording-level WER/CER do not use reference timestamps after the text is constructed, so a *uniform* timing
  offset cannot change them; incorrect word inclusion, crop membership or overlap ordering could. No crop
  construction defect was found (the last included lexical word ends at 1038.31 s; both untimed words fall after
  the crop).

Conclusion: the failed check does not demonstrate a misalignment, and the existing diagnostics do not establish
alignment either. DER/JER are reported conditionally until the manual listening check (follow-up Experiment A)
is recorded.

### 2. D2-rep3 memory anomaly (CHARACTERIZED; CAUSE UNRESOLVED; accuracy unaffected)

D2-rep3 shows sampled peak RSS 337 MiB and peak footprint 330 MiB, against 520 and 490 MiB in rep1 and rep2
(`evidence/phase1/followup/step0/memory-reanalysis.json`):

- It is not one low sample. From about 2–20 s, rep3's footprint is 327–329 MiB against 488–490 MiB in reps 1–2;
  after about 20 s it falls to roughly 220 MiB against roughly 312 MiB, and its late-run median (116.8 MiB) is
  closer to the others (127.1, 129.2 MiB). All three runs took 1042 samples with no missed intervals.
- Prediction content, DER and JER are identical in all three runs. The performance sample differs too: rep3's
  active service time is lower (85.5 s vs 89.8 / 89.7 s), and that variation stays in the reported range.
- The supervisor's observations are also lower (858.0 / 857.8 / 442.1 MiB), but the supervisor polls **one runner
  PID** (`ps -o rss= -p <pid>`), not the process tree, over a longer window that includes post-telemetry artifact
  construction and scoring. Its values are therefore a different measurement window from the in-process sampler,
  and neither is a complete process-tree or system peak.
- Recorded conditions (AC power, memory pressure level 1, thermal state `nominal` — which can also mean
  unsupported — and load average about 1.0–1.5) were the same before every D2 run. rep3 ran last (05:46).
- Hypotheses, none tested or favored: compiled-model or device cache state, page residency/reclamation, runtime
  allocation differences, or accounting changes between launches.

Treatment: rep3 is valid and retained; peak memory is cited as a range, never as one exact requirement.

### 3. A2 native finalization edge cases (CONFIRMED IN SOURCE; DID NOT AFFECT THESE RUNS)

Model-free tests drive the unmodified speech-swift `StreamingSession` with stub models and scripted token/EOU
outputs (`Tests/SpeechNativeEOUTests`). They confirm that the native session (a) drops a genuine final whose text
equals the previous final, after consuming its tokens; (b) discards a final confirmed inside `finalize()`'s padded
trailing chunk, leaving the recording final without that segment; and (c) never decodes audio after its single
trailing chunk — for this crop, the last 3200 samples (200 ms, after 1039.68 s), where the reference has no words.
Each of (a) and (b) leaves a detectable signature in the saved recording partials (non-prefix rollback, or a final
that differs from the last partial). A read-only audit of all three A2 traces found **no** such signature
(`evidence/phase1/followup/step0/asr-rollback-audit.json`), so neither mechanism removed text from the reported A2
output. A2's configuration identity is unchanged. A further native behavior — the greedy decoder stops a chunk at
an `<EOU>` token, so that chunk's later frames are never decoded — cannot be audited from saved traces; its
effect on these runs is unknown. These are limitations of the native A2 configuration, so A1 vs A2 is not a pure
model-accuracy comparison. Details: [PHASE_1_FOLLOWUP_RESULTS.md](PHASE_1_FOLLOWUP_RESULTS.md).

## Configuration differences that limit comparability

Classification: both pairs are `best_practical`, not matched-model.

| Aspect | FluidAudio | speech-swift |
|---|---|---|
| Sortformer export | v2.1 low-context, FP16 BNNS-fixed (`fastV2_1`) | v2.1 streaming, FP16 compute / FP32 I/O, separate conversion repo |
| Sortformer post-processing | pass-through 0.5 thresholds on a timeline | 0.3 s minimum speech, 0.15 s gap merge, speaker IDs compacted |
| Sortformer output timing | Samples | Float seconds (a frame-boundary value such as 1199.92 s can land one sample past the frame) |
| Parakeet EOU precision | FP16 storage, 320 ms chunks | INT8-palettized encoder storage (INT8 arithmetic not established) |
| Parakeet decoding | cumulative decode via callback (`process` returns empty text) | EOU-segmented finals; native edge cases in validity item 3 |
| Compute units | `all` requested | `all` forced through an environment variable; default is `.cpuAndGPU` |
| Offline operation | sandbox denies network | explicit cache directory and `offlineMode: true` through the owned copy (DEC-079); sandbox also denies network |
| Build | same joint binary and `Package.resolved` for all rows | same |

Observed compute placement is not available for any row, so "all" is a request, not evidence that the ANE ran.
The independent review lists further differences (D1/D2 cache-update period, D2 rebuilding its whole-history
snapshot on every push) that are not re-verified here.

## Resolved issues and unresolved limitations

Resolved:
- All 12 runs genuinely completed and validated (re-verified).
- Determinism: prediction content is identical across repetitions for every row.
- The two A2 native finalization edge cases named in the review did not remove text from the saved A2 outputs
  (model-free reproduction plus saved-trace audit).
- Report script changes reviewed (11 campaign tests pass, compiles); the report was generated into a new directory.

Unresolved (also in `review-package/unresolved-issues.md`):
1. Acoustic alignment: the automatic RMS spot check failed its uncalibrated threshold, and the manual listening
   check (follow-up Experiment A) has not been recorded. DER/JER are conditional.
2. One 17.3-minute meeting with four speakers; no variance across audio, and repetitions add no accuracy variance.
3. References are frozen projections: recording-text linearization (not speaker-attributed WER) and word-union speaker
   activity, which is not standard AMI segmentation and not comparable with published AMI DER or WER.
4. Both upstream model cards list AMI among their training data, so this is not an unseen-holdout result; whether
   ES2008a itself was included is unknown.
5. D1 vs D2 and A1 vs A2 differ in conversion, precision, post-processing and native decoding behavior; differences
   are not attributable to the framework, precision or accelerator alone.
6. D2-rep3's lower early memory is characterized but unexplained.
7. Prepare, first inference and cold-start behaviour are not isolated; memory is runner-process sampled data;
   GPU/ANE/power are unmeasured; maximum throughput is unmeasured.
8. A2's frame skipping after an `<EOU>` token has unknown effect on these outputs.
9. The reporting changes are uncommitted, so the generated report records a dirty tree.
10. Optional VoxConverse was skipped (no lawful audio with matching RTTMs supplied).

## Corrections (2026-10-26)

Made after the independent review; the measured values were not changed.

| Earlier statement | Correction | Basis |
|---|---|---|
| "all four rows run roughly 11–13x faster than real time" | Withdrawn. Service RTF is accumulated adapter wall time during 1x paced replay; throughput was not measured. | Review F01; `timing.py` definition |
| Replay and end-to-end RTF "are 1.00 by construction" | They are about 1 because processing kept up; they would exceed 1 otherwise. | Review, performance table |
| Alignment "RESOLVED … supported to about 0.25 s"; "DER rises steeply with any shift"; "both independent models agree" | Not resolved; D2 DER improves at +80/+160 ms; the diarizers are not independent ground truth. | Review F02; re-computed sensitivity table |
| Deletions "spread evenly across the thirds"; "no end-of-file truncation" | Not evenly distributed (184/70/197, 188/73/208); late words argue only against wholesale truncation. | Review F03; re-computed alignment |
| "Peak memory is a model-load transient … peaks in the first seconds"; "memory reaches its peak within the first samples" | Footprint peaks 12–20 s into the run, after prepare; cause not isolated. All three late-run medians reported. | Review F06; uniform reanalysis |
| D2-rep3 "EXPLAINED … NO EFFECT ON RESULTS"; "supervisor's tree peak" | Characterized, cause unresolved; performance also differs; supervisor observes one PID, not the tree. | Review F07; `run_phase1.py` `ps -p` |
| "memory size was not re-verified here" | 17,179,869,184 bytes recorded in all 12 environment files. | `environment.json` |
| A2 "consecutive identical finals suppressed" listed only as a design difference | Confirmed native loss edge cases; audited as not affecting these runs. | Follow-up Step 0 |

## Scope boundaries

Phase 1 stops here; follow-up checks are recorded in [PHASE_1_FOLLOWUP_RESULTS.md](PHASE_1_FOLLOWUP_RESULTS.md).
No Phase 2 work was started. Anything cited publicly must come from the tables above, carry the single-meeting,
custom-reference and best-practical caveats, and avoid ranking the frameworks.
