# Phase 1 independent engineering review

Reviewed 2026-10-26 (Asia/Kolkata). Scope: Apple Silicon Voice Engine, campaign `20261021-s2`, four configurations, three fresh-process repetitions each. This review evaluates the implementation and saved evidence independently of the previous narrative.

## Decision

| Area | Verdict | Meaning |
|---|---|---|
| Benchmark execution | **PASS** | All 12 measured runs completed with consistent sealed artifacts, lossless input accounting, and the intended real adapters. |
| Accuracy | **CONDITIONAL** | The arithmetic reproduces. The custom reference definitions, unresolved acoustic alignment, and native ASR finalization limitations constrain interpretation. |
| Performance | **CONDITIONAL** | Adapter service time, paced replay, and scoped process telemetry are usable. An 11–13x end-to-end throughput claim is unsupported. |
| Framework comparison | **CONDITIONAL** | A descriptive comparison of four pinned configurations is valid. A causal comparison of frameworks is not established. |
| Publication readiness | **CONDITIONAL** | A credible engineering case study is possible after correcting the throughput claim and closing the small validation gates below. |

**Findings: 1 P0, 7 P1, 2 P2.** P0 denotes a required correction to the interpretation, not evidence that the campaign must be discarded. No scoring arithmetic defect or demonstrated corruption of the saved predictions was found.

The next action is to correct the service-RTF interpretation, perform the short manual alignment check in the [follow-up plan](PHASE_1_FOLLOWUP_PLAN.md), and check the two native A2 finalization edge cases with model-free inputs before further model experiments. A full repeat of the original campaign is not justified by this audit.

## Scope, evidence, and verification

Paths below are relative to the repository root. `E` abbreviates `evidence/phase1/one-shot/20261021-s2/`; `R` abbreviates `E/campaign/runs/`. Evidence is git-ignored and must be retained locally to resolve these paths. All requested primary files and the review package were present. Original AMI audio/annotations and the four model-asset directories were also available outside the repository under `/Users/atharvapawar/voicebench-phase1-assets/`.

Inspected implementation:

| Area | Source inspected | Evidence inspected |
|---|---|---|
| Phase 0 audio, replay, persistence | `Sources/AudioCore/AudioPreparation.swift`, `PCMSpool.swift`; `Sources/Replay/ReplayScheduler.swift`, `BoundedQueue.swift`; `Sources/Experiment/ExperimentRunner.swift`, `Pipeline.swift`, `EnvironmentCapture.swift`, `EventRecorder.swift` | Runtime summaries, event traces, configs, status seals; Phase 0 readiness/acceptance records |
| Four Phase 1 adapters | `Sources/FluidAudioAdapters/*.swift`, `Sources/SpeechSwiftAdapters/*.swift`, `Sources/RealAdapterSupport/{StreamingWrappers,OutputHelpers,ModelProfile}.swift` | Frozen profiles, assets, predictions and events for all 12 runs |
| Actual SDK behavior | Pinned FluidAudio checkout under `.build/phase1-both/checkouts/FluidAudio/`; `vendor/speech-swift/`; owned patch | Current SDK revisions and diff, model notices, binary and lock hashes |
| Dataset and accuracy | `scripts/prepare_phase1_data.py`; `analysis/src/phase0_analysis/{score,normalization,asr_metrics,diarization_metrics}.py` | Original AMI XML, crop WAV, frozen references, per-run reference copies and metrics |
| Performance and validation | `Sources/Telemetry/*.swift`, `Sources/CTelemetry/TelemetryShim.c`; `analysis/src/phase0_analysis/{timing,resources,validate}.py` | All telemetry sidecars, saved sealed validations, ledger, sandbox controls |
| Campaign and reporting | `scripts/run_phase1.py`, `scripts/report_phase1.py`; related tests | Matrix, campaign summary, snapshots, report JSON/CSVs, review-package scripts and offset sweep |

Lightweight verification performed, without running real models:

- Rehashed every artifact listed in each of the 12 measured runs' `status.json`; every byte count and SHA-256 matched. Streamed all measured event traces to verify sequence continuity, runtime-prefix hashes, scheduled/consumed sample totals, terminal completion, final prediction reconstruction, and adapter stage sums.
- Checked ledger exit/validation codes, no retries or supervisor stops, completed states, initial validation results and saved sealed validation results. Every run consumed all **16,638,080 samples**, with zero drops; all were labelled real. The four smoke controls, four empty-asset controls, and one mock pacing control passed. Sandbox evidence records successful outside-sandbox local connectivity and denied local/outbound connectivity inside the sandbox.
- Rehashed the available campaign executable: `5f8ccfe372b246d2e64b75b23b87706ae94c7c1c71adf2ebbe3c0247261931c8`. It matches the frozen matrix. `Package.resolved` matches `aee60879806d3b495c2794a43743114016a2803e8053d97fc350fc83644c2a3f`. All four profile hashes and all 52 listed current asset files match their recorded identities. This verifies available bytes and the loader's checks, not a reproducible-build proof.
- Independently parsed the original AMI XML, reconstructed recording text and per-speaker interval unions, and compared them with the frozen references. Original input hashes match. Both untimed lexical words occur after a timed word ending at 1041.14 s, outside the crop. The crop's PCM frames exactly equal the source prefix; it is 16 kHz, mono, 16-bit PCM, **1039.88 s**. Independently converting PCM16 to Float32 reproduced the runtime spool hash `b70b5688793b24f368b9d53830c6aca3da34afaf82804e8193f912f8614c9e19`. Runtime conversion records report bypass with no endpoint correction.
- Recomputed WER using an independent single-row Levenshtein dynamic program and CER edit distance using an independent bit-vector implementation. Reproduced jiwer component counts under the repository's normalizer. Independently calculated DER/JER using integer-sample interval integration and exhaustive matching of the four speaker labels, without pyannote's scoring implementation.
- Recomputed adapter service sums, sampled memory maxima, late-run footprint medians and report median/min/max reductions. These match the generated numeric report. Prediction **content** is identical within each configuration across repetitions; complete prediction documents contain run-specific metadata.
- Ran the existing model-free Python checks for ASR, diarization, timing, resources, dataset preparation, campaign and reporting: **80 passed in 8.20 s**. No new tests or benchmark implementation were added.

The tests were invoked with `PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=analysis/src MPLBACKEND=Agg .venv/bin/python -m pytest -q -p no:cacheprovider` and these files: `analysis/tests/test_{asr_goldens,diarization_goldens,timing_metrics,resource_metrics,phase1_data,phase1_campaign,phase1_report}.py`. Temporary audit scripts/results stayed under `/tmp/codex-voice-phase1-review/`; the methods and substantive results are recorded here. The `voicebench validate --run` CLI was deliberately not rerun because it writes new `derived/` evidence; its existing output was inspected and the seals were independently rehashed.

A before/after SHA-256 comparison of **3690 pre-existing tracked and evidence files** found no changes during this review. The pre-existing uncommitted results/reporting edits and untracked history/diff were preserved. The only new repository deliverables are this review and the follow-up plan.

Limitations of this review: no listening test, accelerator profiler, temperature measurement, or model inference was performed. Saved native ASR segment updates and diarization probability histories do not exist in this packet; emitted wrapper events cannot reconstruct everything discarded inside an SDK. The log-RMS diagnostic has a JSON result but no corresponding implementation in the supplied review package. Hardware and software facts below are historical run observations, not measurements of the machine's present state.

## Accuracy assessment

### ASR calculation and references

The scorer is correct for its declared policy. `normalization.py:24–40` applies NFC/casefold/NFC, replaces Unicode punctuation with spaces, collapses whitespace, and preserves symbols. WER uses the resulting tokens. CER removes whitespace and scores Unicode code points. Thus apostrophes split contractions: these numbers should not be compared with a different normalizer or NVIDIA's published AMI WER.

`prepare_phase1_data.py:94–122,195–247,259–277` excludes punctuation and nonlexical elements, keeps lexical repeats, disfluencies represented as words, and truncations, then orders lexical words by start time, channel and word number. Reconstructing the XML yielded **2496 lexical XML words**, **2682 normalized WER tokens**, **10,091 CER code points**, and 26 truncated lexical words. There were no nonpositive timed words or words crossing the crop boundary. The last included lexical word ends at 1038.31 s. Both frozen references match this construction exactly.

This is a recording-level ordering of multiple simultaneous speakers. During overlap, a single recognizer may produce a different valid order or only one speaker; ordinary Levenshtein scoring will penalize that. It is a declared local task definition, not standard AMI ASR or speaker-attributed WER.

| Configuration | WER | S / D / I | Hypothesis tokens | CER | Character S / D / I |
|---|---:|---|---:|---:|---|
| A1 | 0.2330350485 | 134 / 451 / 40 | 2271 | 0.1648003171 | 144 / 1408 / 111 |
| A2 | 0.2378821775 | 132 / 469 / 37 | 2250 | 0.1725299772 | 151 / 1468 / 122 |

WER edit distances are 625 and 638 over 2682 reference tokens; independent CER distances are 1663 and 1741 over 10,091 reference code points. The ASR gap is **13 word edits, or 0.485 percentage points of WER**, on one recording. Equal scores across repeated input do not supply an accuracy confidence interval.

Final-view aggregation is internally consistent. `StreamingWrappers.swift:228–254` feeds each consumed chunk once, drains native updates, and emits exactly one untimed recording final at flush. Fluid's cumulative callback is replaced rather than appended; its `finish()` transcript replaces the cumulative text. A2's wrapper joins finalized native segments by index. `EnvironmentCapture.swift:126–183` and `score.py:25–34` score final events only, so partials are not accidentally concatenated into the hypothesis. Reconstruction from all saved traces matches `predictions.json`; for the saved ASR runs the final also equals the last emitted partial. There is no observed wrapper-level transcript duplication or final-tail rollback.

That finding does **not** establish that the SDK emitted every native segment; see F04. Late words are recognized, which argues against wholesale end-of-file truncation, but matching a transcript suffix cannot prove that no earlier words were omitted. Under the exact scoring policy, deletions by reference-token thirds are A1 **184 / 70 / 197**, A2 **188 / 73 / 208**. They occur throughout the reference but are not evenly distributed, contrary to the results narrative. Token thirds are not equal-duration acoustic windows, and these counts do not diagnose the cause of deletion.

### Diarization calculation and references

`diarization_metrics.py:43–144` unions same-speaker intervals, maps to the stream's sample grid, creates distinct annotation tracks, scores the explicit full-recording UEM including silence, and uses `collar=0`, `skip_overlap=False`. Different-speaker overlaps remain. Speaker labels are matched by the scorer; they are not compared as literal identities. Independent interval integration reproduced:

| Configuration | DER | JER | Missed s | False alarm s | Confusion s | Hypothesis speaker-s |
|---|---:|---:|---:|---:|---:|---:|
| D1 | 0.2456107676 | 0.2433000346 | 180.3800 | 11.0800 | 6.3500 | 636.08 |
| D2 | 0.2037778750 | 0.1989342804 | 117.3995 | 36.4195 | 10.299625 | 724.40 |

The denominator is **805.38 reference speaker-seconds**, not 805.38 seconds of non-overlapped wall-clock speech. The frozen reference contains 167 segments, four speakers, and 28.93 s with at least two active speakers. The observed mappings are D1 `spk0→A, spk1→B, spk2→D, spk3→C`; D2 `spk0→B, spk1→A, spk2→D, spk3→C`.

For the independent check, every reference/hypothesis boundary partitions the UEM into constant-activity intervals. The mapping maximizes total paired intersection over the 24 permutations. In each interval, miss is `max(0, Nref−Nhyp)`, false alarm `max(0, Nhyp−Nref)`, and confusion `min(Nref,Nhyp)−correctly_mapped_pairs`, multiplied by interval duration. JER averages `1−intersection/union` across reference speakers using the installed scorer's matching policy. The sums agree with the saved pyannote results to floating-point precision. This also validates overlap counting and the speaker mapping on this recording; a permutation of IDs has no causal quality meaning.

The reference is the union of **lexical word intervals**, not an independently verified speech segmentation. Nonlexical vocalizations and inter-word gaps can be counted as silence. Scoring all overlap at zero collar makes boundary/reference choices consequential. D2's lower DER is chiefly an observed miss/false-alarm tradeoff: it misses 62.98 fewer speaker-seconds, adds 25.34 false-alarm seconds and 3.95 confusion seconds. This is useful descriptive evidence; it does not identify which conversion or postprocessor is more accurate against a standard reference.

### Acoustic alignment

The frozen RMS check genuinely failed: ratios **1.203 / 1.831 / 1.286**, threshold 1.5. Its implementation (`prepare_phase1_data.py:349–410`) compares arithmetic means of RMS over up to 40 longest speech spans and longest silence spans of at least 0.5 s in each third. It does not use a calibrated alignment statistic or duration-weighted whole-window energy. A noisy multi-headset mix and excluded vocalizations are plausible explanations, not established causes. A ratio above one does not rule out an offset.

`E/alignment-diagnostic.json` reports best envelope lags −10/−20/+10 ms with correlations only 0.27–0.39; best and zero-lag correlations differ by at most 0.0006. That is weak evidence against a gross common shift, not a confidence interval on timing or drift. The saved offset sweep reproduces at its tested offsets. The two diarizers are ports of the same model family and cannot be treated as independent acoustic ground truth.

An additional read-only integer-sample sensitivity calculation gave the following DERs. Positive shift moves the **reference later**, retains the fixed UEM, and reoptimizes speaker matching. It is a diagnostic only; the scoring reference was not changed or tuned.

| Reference shift | D1 DER | D2 DER |
|---|---:|---:|
| −1.00 s | 0.434217 | 0.394831 |
| −0.25 s | 0.306625 | 0.269746 |
| −0.08 s | 0.263193 | 0.223855 |
| 0 | 0.245611 | 0.203778 |
| +0.08 s | 0.249820 | 0.189090 |
| +0.16 s | 0.270481 | 0.187304 |
| +0.25 s | 0.294693 | 0.198901 |
| +1.00 s | 0.437930 | 0.351760 |

D2 improves by **1.647 percentage points** at +160 ms. This may reflect model/postprocessor delay, reference boundaries, or both; it is not a reason to shift the reference. The improvement also contradicts the claim that DER rises with *any* shift. The existing sweep excludes neither a material subsecond error nor local speaker-specific misalignment. There is evidence against a multi-second global mismatch; there is insufficient evidence for the report's “resolved” or “supported to about 0.25 s” accuracy bound.

A short manual listening/reference check is necessary for the intended accuracy case study, not a complete reannotation. Recording-level WER/CER do not use reference timestamps after the text is constructed. Uniform timing offsets cannot change those saved scores; incorrect word inclusion, crop membership or overlap ordering can. No such crop-construction defect was found here. DER/JER remain sensitive to acoustic timing. Experiment A specifies the proportionate check and what to do if it fails.

## Performance assessment

### What each measurement represents

| Measurement | Actual definition and valid interpretation | Unsupported interpretation |
|---|---|---|
| Adapter service RTF | Sum of both roles' `consume` and `flush` wall durations / audio duration (`timing.py:151–166`). Includes awaited backend work, sample handling, transcript assembly and synchronous sink waits. Passive overhead is only about 0.03–0.08 s/run here. | Pure model compute time; measured maximum throughput; a combined ASR+diarization engine's speed. |
| Active processing seconds | Active role's `consume+flush` sums (`report_phase1.py:127–137`). Reproduces 79–90 s distributed over a 1039.88 s paced replay. | Time needed to finish the recording if delivered continuously. |
| Replay RTF | Replay anchor → runtime drain end / audio duration; includes flush/shutdown/drain. All runs are about 1.00004–1.00011. | A saturation benchmark. It can exceed 1 when processing cannot keep up; the pacer alone does not guarantee success. |
| End-to-end RTF | Internal setup start → runtime drain end / audio duration; observed about 1.00051–1.00089. Excludes scoring, final prediction construction/serialization after drain, and time before the internal setup marker. | Whole CLI launch-to-sealed-results time, microphone-to-transcript latency, or intrinsic throughput. |
| Processing lag | Chunk-consumption finish − that chunk's planned end-of-frame delivery deadline (`timing.py:93–95`). Includes scheduler delay, queueing and pipeline work. | Lag of recognized words or of emitted speaker labels. |
| ASR delivery-to-output | Emission − admission of the chunk that triggered that update (`timing.py:122–144`). About 29–33 ms p95. | Acoustic onset/end → correct word, stabilized text, or EOU response latency. It omits model accumulation/lookahead/debounce before the triggering chunk. |
| Model setup | `adapter_prepare` phase, including local profile/asset verification and backend load (`ExperimentRunner.swift:181–184`, `ModelProfile.swift:178–209`). | Isolated cold Core ML initialization or first inference. |
| CPU | Process user+system CPU-time delta / elapsed wall time, on a one-core percentage basis. Includes harness work and idle periods in 1x replay. | Whole-machine CPU, accelerator utilization, or CPU load under saturation. |
| RSS and footprint | Current runner-process `resident_size` and `phys_footprint`, sampled approximately each second; the reported peak is the maximum sampled value. | Exact lifetime peak, total unified-memory use, or a separate model-only allocation. |

The code uses a monotonic clock and invocation/chunk identifiers for joins. Real SDK calls are awaited; no detached wrapper callback tasks were found. These are strengths. The inverse of service RTF, about 11.6–13.0, is simply an audio-duration/adapter-service-time ratio. All actual full recordings were replayed at 1x. Continuous input changes scheduling, sustained thermal load, cache behavior, recorder contention and overlapping work. The “11–13x faster than real time” sentence in `docs/phase1/PHASE_1_RESULTS.md:81–84` therefore needs correction.

The no-loss coverage, near-1 replay RTF and bounded observed lag support **keeping up with 1x replay in these separate single-model runs**. They do not promise every frame finishes within 20 ms: rep1 maximum chunk lags are approximately 103/122/162/150 ms for D1/D2/A1/A2. Diarization labels are intentionally emitted only at end of stream, so the benchmark does not demonstrate a low-latency online diarization product.

All rows request Core ML `all` in the profiles. Both Fluid loaders set this request explicitly; speech-swift validates `SPEECH_COREML_COMPUTE_UNITS=all`, and its resolver overrides the EOU loader's `.cpuAndGPU` defaults (`run_phase1.py:458–465`, `SpeechSortformerAdapter.swift:20–33`, vendor `ParakeetStreamingASR.swift:206–235`). Generic run placement fields nevertheless say `unspecified`; observed placement is unavailable. Neither an ANE filename, model-card claim nor low CPU percentage proves actual placement. Apple's [Core ML explanation](https://developer.apple.com/videos/play/wwdc2020/10686/?time=963) describes `all` as making a model eligible for the Neural Engine, not as a placement measurement.

Measured runs followed model smoke tests and reused on-disk compiled assets. Fresh processes do not imply cold OS/device caches. AC power and before/after pressure/load records are useful; all 1042 thermal samples per run say `nominal`, but the implementation explicitly warns that this enum can also mean unsupported. There are no temperatures, frequency traces, accelerator counters, energy measurements, or controlled ambient/background-load conditions. No fanless sustained-throughput, thermal-throttling or energy-efficiency claim follows.

### Memory and D2-rep3

| Row | Sampled RSS peaks, reps 1 / 2 / 3 (MiB) | Sampled footprint peaks (MiB) | Late-run footprint medians, reps 1 / 2 / 3 (MiB) |
|---|---|---|---|
| D1 | 526.8 / 525.9 / 526.1 | 496.8 / 497.0 / 497.0 | 104.7 / 136.8 / 136.8 |
| D2 | 520.3 / 520.4 / 337.3 | 490.5 / 490.4 / 329.5 | 127.1 / 129.2 / 116.8 |
| A1 | 711.8 / 712.1 / 712.6 | 668.8 / 668.7 / 668.9 | 328.9 / 329.0 / 329.2 |
| A2 | 514.9 / 512.4 / 512.8 | 479.2 / 479.7 / 479.7 | 220.6 / 222.6 / 222.3 |

Late-run figures use the 500 samples immediately before the final `end` sample, while the models remain loaded, consistently for every repetition. They are supplementary process measurements, not proof of a stationary model-memory requirement. In particular, D1 varies substantially; publishing rep1 alone hides that variation.

D2-rep3 is not merely one lower sample. At approximately 2–20 s, footprint is roughly 327–329 MiB versus 488–490 MiB in reps 1–2. At about 21 s it drops to about 220 MiB versus 312 MiB; later it is closer to the other runs. All runs have 1042 samples and no missed intervals. Prediction content and accuracy match; active service time is also lower in rep3 (85.48 s versus 89.78/89.70 s). That performance variation must remain in the range.

The supervisor peaks are also lower: D2 approximately 858.0 / 857.8 / 442.1 MiB. However, `run_phase1.py:387–422` uses `ps -o rss= -p <pid>`, **one PID, not the process tree**. This polling continues beyond inference into final artifact/scoring work. In-process telemetry stops before shutdown (`ExperimentRunner.swift:230–251`); prediction construction then reads the approximately 187 MB trace into memory (`EnvironmentCapture.swift:126–136`). These are different measurement windows and neither is a complete tree/system peak. Post-telemetry artifact work is a plausible contributor to the larger supervisor observations, not a proven attribution of their maxima.

Observed footprint peaks occur around 12–20 s into the run, well after the ~0.25 s prepare phase. Calling the whole transient “model load” is a hypothesis. Cache reuse, page residency/reclamation, runtime allocations and accounting changes are plausible; none is isolated. Matching outputs support retaining rep3 for functional/accuracy purposes. They do not explain memory behavior or establish “no effect” on performance. Keep rep3, disclose all ranges, and leave the cause unresolved.

## Findings register

### F01 — P0: Service time is presented as demonstrated 11–13x processing speed

- **Status:** Confirmed interpretation defect.
- **Evidence and location:** `docs/phase1/PHASE_1_RESULTS.md:81–84`; `analysis/src/phase0_analysis/timing.py:151–166`; `scripts/report_phase1.py:127–137`; `R/*/runtime_summary.json` and `metrics.json`.
- **Explanation:** Service RTF includes wrapper/sink wall time and omits paced idle periods and some pipeline work. Compute-only RTF is explicitly unavailable. No accelerated real-model replay was executed.
- **Impact:** The numeric service sums remain valid; the implied throughput conclusion does not. This does not invalidate execution or accuracy.
- **Action:** Replace the speed claim with the measured adapter-service ratio and 1x no-loss result before publication or using it to justify later capacity experiments. Run experiment C only if a throughput claim is wanted. No code correction or campaign rerun is needed to withdraw the unsupported claim.

### F02 — P1: Alignment is more weakly established than “resolved” implies

- **Status:** Confirmed validation limitation; actual acoustic offset is unproven.
- **Evidence and location:** `E/datasets/dataset-freeze.json` → `acoustic_spot_check`; `E/alignment-diagnostic.json`; `E/review-package/analysis/{sweep.py,alignment-offset-sweep.json}`; `scripts/prepare_phase1_data.py:349–410`; results validity section.
- **Explanation:** Uncalibrated RMS and weak envelope correlation do not bound timing error. Minimum DER against model output is not independent ground truth. The finer sensitivity table above demonstrates material subsecond sensitivity. Dataset preparation records `ready` even when the acoustic check fails, and campaign/structural validators do not make that check an accuracy gate; structural readiness must therefore be distinguished from reference validation.
- **Impact:** DER/JER interpretation remains conditional. Saved recording-text WER/CER arithmetic is unaffected by timing alone; reference membership would matter if incorrect. The wrapper/content checks do not resolve acoustic alignment.
- **Action:** Perform A; qualify alignment until then. If a real mismatch is found, create a new version of affected references and derived scoring; retain the original evidence. Do not choose a reference offset by minimizing model DER.

### F03 — P1: Custom reference/task definitions constrain accuracy claims

- **Status:** Confirmed methodological limitation; no reconstruction or scoring defect found.
- **Evidence and location:** `scripts/prepare_phase1_data.py:53,94–122,218–277`; `analysis/src/phase0_analysis/normalization.py:24–40`, `diarization_metrics.py:97–144`; `E/datasets/*.transcript.json`, `*.speakers.json`; `R/{A1,A2,D1,D2}-rep1/metrics.json`.
- **Explanation:** Mono overlap linearization and lexical word-union speech are different targets from speaker-attributed transcription and standard speech segmentation. Zero collar/overlap scoring exposes boundary and nonlexical-policy differences. The normalization adds contraction-derived tokens.
- **Impact:** Arithmetic is trustworthy for the frozen projections. Absolute scores are not standard AMI results; miss/false-alarm differences may partly reflect reference policy. Deletion counts cannot be assigned to a model defect from these metrics alone.
- **Action:** Name these policies beside public scores, retain the component breakdown, and remove “spread evenly”/definitive omission-cause language. A second meeting should initially keep the same policy; adopt official segmentation only as a separately labelled future accuracy question.

### F04 — P1: Native A2 final handling can lose text under identifiable conditions

- **Status:** Confirmed source-level edge cases; occurrence and size of any effect in this campaign are **unverified**.
- **Evidence and location:** `vendor/speech-swift/Sources/ParakeetStreamingASR/StreamingSession.swift:214–244,374–389`; `Sources/RealAdapterSupport/OutputHelpers.swift:205–245`; `StreamingWrappers.swift:240–254`; `Tests/RealAdapterTests/RealAdapterTests.swift:334–355`; A2 saved events/predictions.
- **Explanation:** (1) Native EOU handling advances token offset/segment index before suppressing a final whose text equals the previous final. Legitimate repeated utterances can satisfy that equality. The wrapper cannot recover a final never emitted. (2) `finalize()` discards the update returned by its padded trailing `processChunk`. If that call itself finalizes a nonempty segment and advances `eouTokenOffset`, the following pending-token check can return an empty list, losing that final. The wrapper's recording final includes only finalized segments and does not fail on an open native segment; superseded open partials are deliberately dropped. Existing fake-backend tests demonstrate the wrapper policy, not the native EOU edge cases.
- **Impact:** The saved final view faithfully reflects emitted events, and no final/last-partial rollback was found. That does not prove native-token completeness. The observed 13-edit A1/A2 gap cannot be attributed solely to quantization or recognition quality; the loss mechanism's actual contribution is unknown. Fluid's cumulative finish path differs.
- **Action:** Before another ASR campaign, run two small model-free checks: repeated identical utterances across genuine EOU boundaries, and EOU firing on the padded final chunk. Record native segment IDs/final transitions on a subsequent run if needed. If behavior is corrected later, use a new adapter/profile identity and a new baseline; do not silently relabel old A2 results or append open partials speculatively.

### F05 — P1: Configuration differences and unequal wrapper work confound framework attribution

- **Status:** Confirmed comparison limitation; causal contributions remain hypotheses.
- **Evidence and location:** `E/campaign/profiles/*.json`; `scripts/run_phase1.py:193–215`; `Sources/{FluidAudioAdapters,SpeechSwiftAdapters}/*.swift`; vendor `Sources/SpeechVAD/SortformerStreamingSession.swift:105–140`, `SortformerDiarizer.swift:375–423`; Fluid `DiarizerTimeline.swift:72–88` in the pinned checkout.
- **Explanation:** D1/D2 differ in conversion, binarization, minimum speech/gap handling, preprocessing/state implementation and cache-update period (**31 vs 32**), despite shared C/L/R/FIFO/cache sizes. D2 also rebuilds/binarizes its growing whole-recording history on **every 20 ms push**, even when no new confirmed model frames are produced; the adapter discards that snapshot. D1 updates a retained timeline incrementally. A1/A2 differ in FP16 storage versus INT8-palettized encoder storage, frontend/decoder and text aggregation; INT8 storage does not establish INT8 arithmetic. `all` is only requested eligibility, and generic placement records say unspecified.
- **Impact:** Service-time differences include SDK work outside inference; D2's repeated history scan can scale with recording length. Its exact cost was not isolated. Accuracy/memory differences are observations of configurations, not effects of the framework, model precision or accelerator alone. Speaker-ID compaction itself is neutral under correct matching.
- **Action:** Keep the best-practical configuration framing. Use D if isolating postprocessing is worth the small extra work; it still will not match conversions. Avoid a framework winner or an ANE/quantization causality claim. Do not refactor the streaming APIs just to improve benchmark rankings.

### F06 — P1: Memory and initialization scopes do not support cold-start or model-only claims

- **Status:** Confirmed measurement limitation and supervisor-scope misdescription.
- **Evidence and location:** `Sources/CTelemetry/TelemetryShim.c:23–42`; `Sources/Telemetry/TelemetrySampler.swift:52–143`; `Sources/Experiment/ExperimentRunner.swift:174–184,230–251`; `EnvironmentCapture.swift:126–136`; `scripts/run_phase1.py:387–422`; `analysis/src/phase0_analysis/resources.py:38–61`; all telemetry sidecars.
- **Explanation:** One-second process samples can miss short peaks; pre-load baseline, asset hashing, load, first inference and page reclamation are not separately isolated. Telemetry ends before later artifact processing. Supervisor polling observes one runner PID across a longer window, not the tree. Peak timing does not identify allocation cause, and prior smokes warm shared caches.
- **Impact:** Sampled maxima and late-run footprints are usable with units/window/scope. Model-only memory, exact lifetime/system peaks, pure load time and cold-start costs are not established. Lower A2 memory is not proven to be caused by INT8 storage alone.
- **Action:** Relabel the scopes and describe prepare as prepare. Reanalyze all existing repetitions consistently before rerunning anything. Use targeted E only if load/steady-memory behavior is a publication focus; true OS-cold testing is optional and must be labelled separately.

### F07 — P1: D2-rep3 is characterized, not explained

- **Status:** Confirmed anomaly; root-cause proposals are hypotheses.
- **Evidence and location:** `R/D2-rep{1,2,3}/{telemetry.jsonl,runtime_summary.json,metrics.json,predictions.json}`; `E/campaign/ledger.jsonl`; results section headed “EXPLAINED, ROOT CAUSE UNRESOLVED, NO EFFECT ON RESULTS”.
- **Explanation:** A sustained lower early footprint, lower supervisor RSS and lower service sum coexist with identical predictions. No recorded cache/allocation/placement measurement explains the difference. Nominal thermal state and normal pressure do not eliminate cache or accounting differences.
- **Impact:** Accuracy determinism survives; a single precise D2 memory requirement does not. The performance sample varies too. Excluding rep3 as invalid would be unjustified.
- **Action:** Retain all three, report ranges, rename the conclusion “cause unresolved”, and avoid a Core ML cache explanation presented as fact. If needed, three short D2 fresh-process repeats in E are proportionate; a complete new 12-run campaign is not.

### F08 — P1: One meeting does not establish generalization or an unseen evaluation

- **Status:** Confirmed coverage limitation and corpus-level training exposure; exact meeting exposure is unknown.
- **Evidence and location:** `E/campaign/matrix.json`, `datasets/dataset-freeze.json`; `scripts/run_phase1.py:350–357,583–616`; upstream [Sortformer model card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1#datasets) and [Parakeet EOU model card](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1#training-testing-and-evaluation-datasets), checked 2026-10-26.
- **Explanation:** Both upstream cards list AMI in training; this is stronger than merely speculating about corpus overlap, but does not establish ES2008a's inclusion. Repetitions reproduce one recording; order alternation is only partially balanced (F/S twice, S/F once), and the host is not fully controlled. ES2008b shares this scenario's participants and its first 60 s was already used for smoke testing.
- **Impact:** No significance, unseen-data, broad meeting-quality or framework-generalization claim follows. Three equal accuracy repetitions are determinism evidence, not three independent accuracy samples. Current data do not characterize simultaneous ASR+diarization operation.
- **Action:** Use B for a small within-session robustness check if a broader accuracy narrative is wanted. One run per configuration is initially sufficient on the second meeting; reserve repetitions for performance questions or observed nondeterminism. Do not call ES2008b a new independent-speaker holdout.

### F09 — P2: Source provenance metadata needs a small cleanup

- **Status:** Confirmed stale metadata; current actual source is reconstructible.
- **Evidence and location:** `vendor/speech-swift/PHASE1_VENDOR.json`; `scripts/run_phase1.py:147–175`; `patches/speech-swift-3f58a58a-phase1.patch`; `Package.swift:53–58`; `E/snapshot-{start,end}.json`; current Git status.
- **Explanation:** The vendor record names the obsolete manifest-only patch and lists one changed file. Actual vendor diff is exactly the present two-file patch: both hashes equal `1984bb57276034b28a6d7372174433521402701846c0cf4a4c5774d446da73d9`. The record's old hash starts `a7cd74df`. The reporting script and results narrative were already uncommitted when this review started; measured run configs record clean `e29f345`. Reporting dirtiness does not retroactively make the runs dirty.
- **Impact:** No numeric discrepancy or unexplained inference-source modification was found. The stale inventory can mislead someone recreating the build; a path dependency is not pinned by `Package.resolved` alone.
- **Action:** In a future source/document cleanup, regenerate or correct the vendor inventory and save the actual patch/source identities with the reporting version. Preserve historical snapshots. A new build or model run is unnecessary to document these known bytes.

### F10 — P2: Report eligibility assumes prior validation and counts runs rather than distinct repetitions

- **Status:** Confirmed defensive gap, with no observed effect in this campaign.
- **Evidence and location:** `scripts/report_phase1.py:63–112,160–170,197–204`; `analysis/tests/test_phase1_report.py`; `E/campaign/ledger.jsonl`.
- **Explanation:** Eligibility trusts a ledger `validate_exit_code` and a completed marker, without freshly verifying seals; it does not independently require supervisor exit 0/no stop, bind the executable digest, or ensure three distinct successful repetition IDs when computing COMPLETE. That is acceptable only under the unchanged-evidence assumption. Here the independent seal, exit, binary and distinct-repetition checks all pass.
- **Impact:** No reason to reject the present 12 runs. A later edited ledger or duplicate successful entry could produce an overconfident report without equivalent experimental evidence.
- **Action:** Optional small reporting hardening: consume read-only sealed-validation results, enforce exit/no-stop and unique `(row,repetition)`, and report source/binary identities. Keep execution completeness separate from reference/scientific validity; avoid a new validation framework.

## Framework comparison: observations versus explanations

| Verified observation | Plausible explanation | Causal conclusion supported? |
|---|---|---|
| D2 has lower DER, much less missed speech and more false alarm than D1 on this reference. | Binarization/gap merging, conversion outputs, frontend/state handling, or reference mismatch. | No individual cause isolated. The miss/false-alarm tradeoff itself is observed. |
| D1 has lower accumulated service time than D2. | Incremental timeline work versus repeated full-history snapshots, model execution and preprocessing differences. | No framework/inference-speed advantage established. |
| A2 has lower sampled process memory than A1. | Smaller palettized assets, loader/runtime work, page accounting, different frontend/decoder state. | No isolated quantization effect; storage differences are verified. |
| A1 has 13 fewer word edits than A2. | Conversion/decoder/aggregation differences, overlap ordering, and native final-handling behavior. | No framework or precision accuracy winner established. |
| All four complete 1x with zero lost samples. | Sufficient capacity for the tested separate single-model replay workload. | Yes, for that workload and recorded host conditions only. |

## Publication gates and supported claims

The strongest case study is about engineering a reproducible local comparison and discovering how measurement definitions change the conclusions. The measured results are substantial enough for that story; broad performance or accuracy claims would weaken it.

Supported now, with scope stated:

- Four pinned local configurations each completed three fresh-process, network-denied, lossless 1x replays of one 1039.88 s AMI headset-mix crop on an M5 with 16 GiB observed memory.
- Final output content was deterministic across these repetitions, and independent scoring reproduced the frozen custom-policy metrics.
- DER components reveal a speech-coverage tradeoff; adapter service time is small relative to audio duration; process memory has a substantial early transient and an unresolved D2 outlier.
- Integration differences include SDK output semantics, final-only diarization publication, different postprocessors and a narrowly scoped offline-loader patch.

Claims requiring explicit qualification: all absolute accuracy values; deletion explanations; sampled process-memory rankings; model prepare time; nominal thermal state; and comparisons of named configurations. Hardware memory is actually recorded as **17,179,869,184 bytes in all 12 environment files**, so the results narrative's “memory size was not re-verified here” can be replaced with the recorded fact. Apple's [model identification page](https://support.apple.com/en-gb/102869) maps `Mac17,3` to the 13-inch M5 MacBook Air; architecture and memory are also explicit in the run evidence.

Do not publish as findings: measured 11–13x end-to-end throughput; 29–33 ms word/EOU latency; isolated cold starts; exact model-only/system unified-memory use; proven ANE execution, energy efficiency or absence of thermal throttling; a winning framework; a quantization-caused speed/accuracy/memory effect; independent-speaker/unseen-AMI generalization; a resolved memory cause; or proof of sub-250 ms reference alignment from DER alone.

Before publishing an accuracy-bearing case study: correct F01 and the overstated alignment/deletion/memory wording; record experiment A's result; resolve or explicitly demonstrate the impact boundary of F04 with model-free checks; and preserve accessible methods, hashes, policies and source references in the GitHub write-up. If these gates remain open, a narrowly scoped implementation/methodology case study can still describe them as open limitations and should withhold validated-accuracy claims. Experiments B/C/D/E are conditional extensions of particular claims, not mandatory infrastructure for publication. No LinkedIn post is drafted in this review.
