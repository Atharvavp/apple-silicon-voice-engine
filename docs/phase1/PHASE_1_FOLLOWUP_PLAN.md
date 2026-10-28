# Phase 1 minimal follow-up plan

Prepared 2026-10-26 (Asia/Kolkata), based on the [independent review](CODEX_INDEPENDENT_REVIEW.md). **This is a plan only. No follow-up was implemented and no additional real-model benchmark was run.** It keeps the original campaign immutable and does not begin Phase 2.

## Priority and stopping rules

The present evidence already supports a useful implementation case study. The smallest publication path is a claim correction, a short listening check, and two model-free ASR edge-case checks. A second 12-run real-time campaign is unnecessary.

| Order | Work | Scientific value / effort | Decision |
|---|---|---|---|
| 0 | Correct interpretation and check A2 finalization semantics | High / low | Before new experiments: withdraw the unsupported throughput claim; model-free EOU checks below. |
| 1 | **A. Manual audio/reference alignment** | Very high / very low | Required for an accuracy-bearing case study. |
| 2 | **C. Accelerated replay throughput** | High / low | Run if retaining any faster-than-real-time throughput claim; otherwise omit. |
| 3 | **B. ES2008b accuracy robustness** | High / low-to-medium, mostly elapsed replay time | Best next dataset check; optional for a clearly single-meeting case study. |
| 4 | **E. Targeted startup/steady memory** | Medium / low-to-medium | Start with free reanalysis; add short D2 runs only if the anomaly/memory claim matters. |
| 5 | **D. Normalized diarization postprocessing** | Medium-to-high / medium | Useful ablation if explaining the DER gap is a central research question; otherwise disclose the confound. |

This ranks value per implementation effort, not absolute importance: B adds more accuracy coverage, while C is much cheaper in model runtime and directly addresses the invalid speed interpretation. D can become priority 3 if the main publication question is why DER differs. Do not run all experiments automatically.

Common rules for any later authorized experiment:

- Use a new session/output directory and immutable profile/reference identities. Keep `20261021-s2` and its report intact; correct interpretations in the publication-facing narrative or a clearly labelled addendum.
- Keep the same binary/model files, sample rate, 20 ms frames, queue 32/block policy, reference/scoring definitions and requested `all` compute units unless a listed experiment intentionally changes one. Record changed source/profile hashes. A corrected ASR decoder/aggregation path is a **new configuration**, not a repeat of old A2.
- Use fresh processes for repeatability questions, alternate framework order where paired, run serially on AC with a reasonably idle host, and retain the existing 60 s cooldown between full model runs. Record load/pressure/power and available thermal state; do not add privileged sensors or a scheduling service.
- Use all samples, not speech-only duration, for throughput RTF. Score both correct output and performance: a faster run that drops audio or silently loses text is not a valid throughput result.
- Record individual results and median/range where repeated. Do not manufacture accuracy confidence intervals from identical predictions. A genuine failed run may get one unchanged retry with the original failure retained; a surprising but valid result stays in the analysis.
- Keep model-free checks separate from performance timing. The current `voicebench validate --run` writes new derived evidence; that is appropriate only inside the **new** experiment packet. For an audit of old data, use read-only functions or temporary output outside the old packet.

Estimates below are planning estimates, not measured results. Model runtime excludes implementation/human review unless stated. Existing full-run supervisor durations also include costly trace processing/scoring after the ~17.3 min replay, so accelerated input does not make the whole CLI finish in adapter service time.

## Step 0: Small correctness and reporting gates

No new models or infrastructure are required.

1. Replace “11–13x faster than real time” with the measured service-time definition: approximately 79–90 s of accumulated active adapter wall time during a 1039.88 s paced replay; all four configurations sustained this separate-model 1x workload. State that compute-only time and saturated throughput are unmeasured.
2. Replace resolved-alignment and explained-memory wording with the actual evidence/uncertainty. Remove the assertion that deletions are evenly distributed. Use all three late-memory observations, not only rep1. Correct the supervisor's scope to one runner PID.
3. Run **two focused native-ASR model-free checks** using injected/stubbed token/EOU results, without Core ML: consecutive genuine utterances with identical decoded text, and nonempty EOU confirmation inside the padded trailing chunk of `StreamingSession.finalize()`. Assert that each legitimate final survives once, recording aggregation contains all finals, and no unresolved nonempty segment disappears silently. Existing fake-backend wrapper tests do not exercise these SDK paths.

Expected effort: 30–90 minutes for the focused checks and a small narrative addendum. If a source correction is warranted later, keep it narrow, pin/hash it, and rerun only affected A2 comparisons under the new identity. Do not redesign the ASR event schema or append a pending partial speculatively. If code remains unchanged, describe these as native-configuration limitations and do not present A1/A2 as a pure model-accuracy test.

## A. Manual audio/reference alignment validation

**Research question:** Do the frozen reference words, speaker identities and timing correspond to the actual mix throughout ES2008a, and does the failed RMS check indicate a real mismatch?

**Hypothesis:** The audio and annotations are globally aligned; low RMS ratios arise from the mix/reference definition rather than a material global shift. This is a hypothesis to check, not an assumed result.

**Required changes:** None to benchmark code. Prepare a small listening worksheet with sample/time positions, original AMI word IDs/text and speaker/channel, and waveform cursors. Use the crop, original XML and, if speaker identity is ambiguous, the existing source headset channels. Write a new validation note with reviewer, date, playback method and observations. No reference edits during inspection.

**Dataset and configurations:** Existing frozen ES2008a crop and its original AMI annotations; no model configuration and no inference. Choose windows from annotation metadata before listening to model outputs: approximately 20–30 s in each third, covering clear isolated turns from all four speakers across the set. Add one overlap/nonlexical interval relevant to the RMS failure and the last 10–15 s around the final lexical words/crop boundary. About 1.5–2.5 minutes of unique audio is sufficient initially.

**Repetitions:** One human pass; replay uncertain intervals. Obtain a second human judgment only for an ambiguous or discrepant boundary, not for the entire recording.

**Metrics/observations:** Heard lexical content versus reference; audible speaker/channel identity; onset/end residuals for at least six clear turns spread over the recording; whether residuals share a sign or grow with time; vocalizations in supposed silence; last included and first excluded words. Distinguish lexical word timing from broad speech-region boundaries. Listening alone cannot establish millisecond precision—use a waveform cursor for any numerical boundary estimate.

**Estimated time:** 10–20 minutes human work, up to 30–45 minutes if a discrepancy needs investigation; zero model time.

**Expected value:** Highest-return resolution of the current accuracy-validation uncertainty, independent of the evaluated model predictions.

**Acceptance criteria:** Correct content and speaker correspondence at the sampled positions; no systematic shift or start-to-end drift exceeding a predeclared **80 ms investigation threshold** at clear boundaries. This threshold is a practical screen tied to the diarizer's 80 ms frame, not a proof of sample accuracy. Ambiguous coarticulation/overlap is recorded as ambiguous, not forced to pass. If timing cannot be judged to that scale, retain a conditional verdict and the measured DER sensitivity. Do not require the RMS ratio to pass after the fact.

If a consistent or local mismatch is confirmed, locate its source (mix/channel origin, XML timing, crop membership), version the affected reference, and rescore saved predictions first. If only reference timing changes, existing recording-text WER need not change; if reference word membership/text changes, recompute WER/CER too. Rebenchmark models only if the supplied audio itself changes. Never align the reference by choosing the offset that gives the lowest model DER.

## B. A second AMI meeting: ES2008b

**Research question:** Do the error patterns and configuration differences persist on a second segment of the scenario, rather than being peculiar to ES2008a?

**Hypothesis:** Output is still deterministic and the broad miss/false-alarm and deletion patterns persist; the exact ordering/gaps may change. No winner is prespecified.

**Required changes:** Select ES2008b through a small explicit meeting-selection input or a separate invocation using an approved meeting inventory restricted to ES2008b; the preparer otherwise prefers ES2008a. Freeze new manifests/references using the existing policies, validate them, and perform the same short alignment screen. Reuse campaign/run entry points with a separately labelled one-repetition exploratory matrix. Do not claim `COMPLETE` under the current three-repeat report gate; summarize these four runs as a separate one-run-per-configuration accuracy extension. No broad orchestration change is needed.

**Dataset:** ES2008b headset mix, prefix [0,1200 s) if still eligible at execution. A metadata-only inspection during this review found the existing `choose_end` policy accepts **1200 s**. Freeze hashes and exclusion counts anew before predictions. Its first 60 s has already been used as the ES2008a campaign's unscored smoke input. It shares participants/scenario with ES2008a, so this is additional within-session coverage, not an independent-speaker or untouched holdout. Use a disjoint later source interval for any new smoke check.

**Configurations:** All four pinned D1/D2/A1/A2 configurations, one active model per run. If A2 changes after Step 0, name the corrected identity and compare the appropriate ES2008a baseline as well; do not pool old/new A2 rows.

**Repetitions:** **One per configuration initially (4 runs)** for accuracy. Add repeats only for output nondeterminism or a specific performance question; repeat identical audio three times solely for accuracy adds little scientific value. Keep B at 1x unless C has already established unchanged output under acceleration; then accelerated runs may be used for the accuracy-only extension with timing labelled separately.

**Metrics:** WER/CER with S/D/I, normalized token counts and reference policies; DER/JER with miss/false alarm/confusion, speech coverage, overlap, matching and duration. Report per-meeting values and differences. A combined ASR score, if shown, sums edit numerators and reference denominators; a combined DER similarly sums error and reference speaker-time. Keep JER per meeting or use explicitly speaker-weighted aggregation, not an unlabelled mean. Do not infer significance from two related meetings.

**Estimated time:** At 1x, 80 min audio replay plus roughly 10–20 min artifact/scoring/cooldown overhead: **about 1.5–2 hours**, plus 20–40 min data review. After C, accuracy-only acceleration could reduce model time substantially; whole-CLI overhead still applies.

**Expected value:** Best small increase in accuracy coverage without adding a new corpus or model family.

**Acceptance criteria:** Valid frozen data, alignment screen passed or explicitly conditional, no loss, one complete final transcript per ASR run, valid final diarization timeline and successful run validation. Publish the second meeting even if the ranking reverses. A reversal is a finding, not an experiment failure. If output is nondeterministic, run two additional repetitions only for the affected configuration and investigate before summarizing.

## C. Accelerated replay for measured throughput

**Research question:** How fast can the existing instrumented single-model pipeline consume and finalize this recording under sustained offered load, with correct output?

**Hypothesis:** All configurations exceed 1x at saturation, but continuous replay speed is not necessarily the inverse of the 1x adapter service RTF.

**Required changes:** Existing `ReplayScheduler` supports accelerated rational speeds. Create separate configs with `mode: accelerated`, `speed: {num: 32, den: 1}`, retaining 20 ms frames, queue 32 and block. No Swift scheduler change is needed. `run_phase1.py` currently emits `speed: null` and the Phase 1 report eligibility requires realtime, so use explicit new configs/the existing CLI and a small separately labelled reduction of metrics; do not pass accelerated runs through that unchanged eligibility gate or pool them with 1x. Save the configured speed and actual replay/flush/drain intervals.

**Dataset/configurations:** Frozen ES2008a audio and references; D1/D2/A1/A2 under the same binary and asset identities. If any correctness fix changes A2, make the new identity explicit and compare against an appropriate correct baseline.

**Repetitions:** One 32x run per configuration first. If correct, expand to **three per configuration (12 total)** for a modest throughput range, alternating pair order. If a run still finishes near the 32x pacing floor and producer blocking is negligible, that row is offer-rate limited: run a single 64x confirmation, adding repetitions only if it changes the conclusion. Do not build a broad speed sweep.

**Metrics:** Audio seconds divided by (anchor → final output/drain) for measured pipeline speed; replay RTF and internal end-to-end RTF separately; externally observed process-launch → sealed-results time separately if used; active/passive service sums; producer blocked time, queue depth, flush/drain duration, consumed/dropped samples, last-chunk lag, CPU/thermal state and scoped memory. Use replay-to-drain for finalized pipeline throughput: the existing `media_seconds_per_second` denominator ends with chunk consumption and excludes flush. Accelerated deadline lag is lateness against the accelerated schedule, not live conversational latency.

**Estimated time:** Planning assumption **1.5–3 minutes of runtime per full recording**, not a prediction of 11–13x. Twelve runs with existing scoring and cooldowns: approximately **35–60 minutes** wall time; allow up to 90 minutes if trace processing dominates. First four pilot runs provide a stop point. Configuration/reduction effort: roughly 30–60 minutes.

**Expected value:** Directly tests the claimed throughput with little implementation work and exposes recorder/wrapper costs under sustained load.

**Acceptance criteria:** Zero lost samples; successful sealing/validation; final transcript/speaker content identical to the same-identity 1x baseline, or any numerical difference investigated before claiming equivalent throughput. Evidence of sustained producer backpressure or speed stability when increasing offered rate is required to call the result saturation throughput. Otherwise publish it as achieved throughput at the stated offered rate/lower-bound capacity. A “≥11x” claim requires observed finalized-pipeline speed ≥11x in every retained valid repetition of the relevant configuration, with range and scope stated. No threshold is required to make an honest descriptive result useful.

D2 currently rebuilds whole-history snapshots on each push. Keep that behavior for this baseline: it is part of the measured configuration. An optimized API would be a separate experiment, not a retroactive repair to C.

## D. Normalized diarization postprocessing

**Research question:** How much of the D1/D2 DER gap is associated with their different segment postprocessing, when that one factor is controlled?

**Hypothesis:** Common segmentation changes the miss/false-alarm tradeoff and may reduce the gap. A residual difference can still come from model exports, feature extraction, cache updates or numerical behavior.

**Required changes:** Existing final segments cannot recover speech discarded by a minimum-duration filter. Do not “normalize” both saved timelines merely by merging segments. The smallest defensible approach is to produce **new raw thresholded timelines** for both SDKs, setting onset/offset 0.5, no padding, no minimum speech, no gap merge. Fluid already uses that policy; speech's binarization can be set per session, but its adapter/profile guard must accept a separately named ablation profile. Re-run both under those identities and apply one external segment-level operator to both raw timelines, using the same operation order and seconds/sample arithmetic.

Two preregistered policies suffice: pass-through, and discard segments shorter than 0.30 s **then** merge same-speaker gaps shorter than 0.15 s. Keep simultaneous different speakers, clip only declared EOS padding, and use the same zero-collar/overlap/UEM scorer. Verify the shared operator with a few hand-derived boundary examples. Avoid tuning thresholds on ES2008a.

If identical pre-threshold binarization is needed, export raw finalized frame probabilities instead: Fluid exposes `timeline.finalizedPredictions`; speech currently keeps `confirmedProbs` private, requiring a small SDK accessor/owned patch. That is a more exact but higher-effort alternative, not necessary for the first segment-policy ablation. Neither alternative matches the model conversions or cache-update cadence. Freeze all changed profile/source identities.

**Dataset/configurations:** ES2008a; D1/D2 only. Use ES2008b later as a confirmation if already available from B, not as a prerequisite. Reuse C's acceleration only after its output-invariance check; keep raw-policy output and the two derived scores separate from the original defaults.

**Repetitions:** One new run per diarizer initially (2 runs), sufficient for a deterministic postprocessing accuracy question; repeat only on unexpected nondeterminism. Applying two policies to one saved raw output requires no additional model runs. If D2's original-default scores are to be regenerated from the raw stream, verify parity before attributing a gap to policy.

**Metrics:** DER/JER and all DER components under each common policy; reference/hypothesis speaker-seconds, segment counts and number/duration of discarded/merged regions. Report the change in the between-configuration gap, without claiming a complete causal decomposition of the original gap.

**Estimated time:** **1–3 hours** for the narrow profile/adapter change and hand checks; ~35 min model replay at 1x plus overhead, or minutes of model runtime after validated acceleration. Probability export may cost longer and should be skipped unless the segment ablation cannot answer the research question.

**Expected value:** A small controlled ablation of the most obvious accuracy confound. Lower value per effort than A/B/C unless explaining DER is central.

**Acceptance criteria:** Both raw outputs preserve speaker overlap and documented boundaries; exactly the same external postprocessor is applied; hand-derived cases pass; all changes/version identities recorded. Report either a reduced, unchanged or reversed gap. If raw-output parity with the relevant native default cannot be demonstrated, present a new common-policy comparison and explicitly avoid assigning a precise percentage of the original gap to postprocessing.

## E. Fresh-process startup and steady-state memory

**Research question:** Is D2's lower third-run early memory repeatable, and which memory/load observations are stable when startup and later windows are reported consistently?

**Hypothesis:** The large early footprint is sensitive to runtime/cache/residency state, while later process footprint varies less. The present data do not identify the mechanism; D1's late-run variation also needs disclosure.

**First action, no new inference:** Reanalyze all 12 existing sidecars using one explicit time window and scope. Publish per-run early maxima, their times and late-run median/range. The independent review already supplies an all-repetition late-500-sample reduction; a fixed media-time window is another acceptable choice if specified. Compare with the longer supervisor-PID window separately. Do not turn differences in these scopes into evidence of extra model allocations.

**Required implementation for new measurements:** Reuse the runner with a new 120 s crop/manifest and **100 ms telemetry interval throughout**, which covers the observed 12–20 s transient rather than only the first second. Keep existing phase timestamps. If isolating Core ML load or first inference is essential, add just local time/memory markers immediately before/after `backend.load` and the first actual native inference—not merely the first 20 ms `consume`, which often buffers audio. Profile hashing time must stay separately identified. A small diagnostic sidecar is enough; do not expand the frozen schema suite or instrument every model operator.

**Dataset/configurations:** ES2008a first 120 s; **D2 initially**, using unchanged model/postprocessing/compute request. Add D1 or A1/A2 only if publishing comparative startup/steady-memory claims that the existing traces cannot support. Do not benchmark all four by default.

**Repetitions:** **Three fresh-process D2 runs**, same machine session, caches retained, 60 s cooldown. This tests repeatability with warmed shared caches, not OS-cold behavior. No same-process adapter reuse/refactoring is required. Reuse the three existing full-length D2 runs for the long steady-state context; a 120 s result cannot alone establish 17 min stability.

**Metrics:** Baseline RSS/footprint, load-phase duration and separately marked first-inference time if added; sampled early peak, peak timestamp; median/min/max footprint over seconds 60–120; CPU and sampler completeness; available pressure/thermal/power state. Log one-PID supervisor observations separately. Report absolute process values and labelled baseline deltas; baseline subtraction does not identify model ownership or total unified memory.

**Estimated time:** Existing-data reduction 15–30 min; markers/config work 30–90 min if needed; 6 min audio replay plus cooldown/artifact processing: **about 10–20 min** for three D2 runs.

**Cold-start distinction:** A fresh process is the default minimal experiment. If an actual cold-first-use claim is indispensable, add one owner-coordinated reboot/first-load observation followed by two warm-cache launches; do not delete global model caches or purge memory. Label it one uncontrolled post-reboot observation, not three cold replicates. A `.mlmodelc` and prior device specialization still complicate “cold”; state exactly what was reset. Without this extra work, publish “fresh-process prepare with shared-cache state uncontrolled” and omit cold-start claims.

**Expected value:** Clarifies stable versus transient scoped memory with a small targeted campaign; may reproduce the anomaly without promising a root cause.

**Acceptance criteria:** Complete 100 ms telemetry and phase accounting; all valid repetitions retained; output/coverage valid; startup and steady windows clearly separated. If the lower peak repeats, describe the distribution. If it does not, keep the historical anomaly unresolved. No allocation/cache cause is accepted without direct discriminating evidence; a tighter range is not proof of cause. Stop after three short repeats unless a new observation would change a specific publication claim.

## Recommended package of work

For the smallest credible publication: **Step 0 + A**, then stop and write the case study with explicit single-meeting/custom-reference/configuration scope. With one additional measurement objective, choose **C for a throughput story** or **B for an accuracy robustness story**. E and D are optional investigations; choose them only to answer a central claim. None of these requires Phase 2, a new corpus pipeline, model retraining, a large benchmark service, or a broad harness refactor.
