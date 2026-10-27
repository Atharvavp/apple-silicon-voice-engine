# Phase 1 follow-up results

Started 2026-10-26 (Asia/Kolkata). Executes the approved subset of the [follow-up plan](PHASE_1_FOLLOWUP_PLAN.md)
(Step 0, then A, C, B; D and E are out of scope) after the [independent review](CODEX_INDEPENDENT_REVIEW.md).
The original campaign `evidence/phase1/one-shot/20261021-s2/` is unchanged (625-file SHA-256 manifest identical
before and after Step 0). Phase 2 has not started.

**Status: Step 0 COMPLETE. Experiment A, C and B NOT STARTED (awaiting checkpoint review).**

## 1. Executive summary

- **Throughput claim withdrawn.** "11–13x faster than real time" was the inverse of accumulated adapter service
  time during 1x paced replay, not a throughput measurement. The supported statement is that all four
  configurations sustained separate-model 1x replay with zero lost samples, using about 79–90 s of active adapter
  wall time per 1039.88 s of audio. Experiment C would measure finalized-pipeline throughput directly.
- **Alignment, deletion and memory wording narrowed.** Every number cited in the corrections was recomputed
  independently from the saved evidence and matched the review.
- **A2 native finalization: both edge cases reproduce, but neither affected the reported A2 results.**
  Model-free tests drive the unmodified speech-swift session. They confirm that (a) a genuine final identical to
  the previous final is dropped and (b) a final confirmed inside `finalize()`'s trailing chunk is discarded.
  A read-only audit of the saved traces, validated against those exact signatures, found neither in A2 reps 1–3.
  No source fix is required for the existing baseline, and A2's configuration identity is unchanged.
- **Two further native behaviors were found** and characterized, outside the review's two checks. (c) Audio after
  the single trailing chunk is never decoded: 200 ms at the end of ES2008a, which has no reference words there, and
  0 ms for a 1200 s ES2008b crop. (d) A chunk's frames after an `<EOU>` token are not decoded. (d) cannot be
  audited from saved traces, so its effect is unknown.

## 2. Step 0 findings and corrections

### 2.1 Reporting corrections

`PHASE_1_RESULTS.md` was corrected in place, with a corrections table. The pre-review text is kept in
`docs/phase1/history/PHASE_1_RESULTS-20261021-s2-pre-review.md`. The measured values were not changed.

| Item | Correction | Independent recomputation (`evidence/phase1/followup/step0/`) |
|---|---|---|
| Throughput (F01) | Service RTF described as accumulated `consume`+`flush` wall time during 1x replay; throughput unmeasured; replay/end-to-end RTF ≈1 because processing kept up, not "by construction" | Service RTF 0.0763–0.0864; replay RTF 1.00004–1.00011; end-to-end 1.00051–1.00089; max chunk lag 103–259 ms (`memory-reanalysis.json`) |
| Alignment (F02) | "RESOLVED / supported to about 0.25 s" withdrawn; DER/JER conditional pending A | Shift table reproduced exactly; D2 DER 0.2038 → 0.1873 at +0.16 s (`der-shift-sensitivity.json`) |
| Deletions (F03) | "spread evenly" removed; truncation wording narrowed | Deletions by reference-token thirds A1 184/70/197, A2 188/73/208 (jiwer alignment under the repository normalizer) |
| Memory (F06) | Peak not called a model-load transient; peak time 12–20 s; all three late-run medians; runner-process, 1 s sampled scope | D1 104.7/136.8/136.8, D2 127.1/129.2/116.8, A1 328.9/329.0/329.2, A2 220.6/222.6/222.3 MiB; footprint maxima at 12–20 s |
| D2-rep3 (F07) | "EXPLAINED / NO EFFECT" → characterized, cause unresolved; service time differs too | rep3 2–20 s footprint 327.3–329.0 vs 488.3–490.0 MiB; active service 85.5 vs 89.8/89.7 s |
| Supervisor scope (F06) | Observes one runner PID (`ps -o rss= -p <pid>`) over a longer window, not the process tree | `run_phase1.py:389`; peaks D1 ≈864, D2 858.0/857.8/442.1, A1 ≈1040, A2 850–853 MiB |
| Hardware memory | Replaced "not re-verified" with the recorded value | 17,179,869,184 bytes in all 12 `environment.json` files |

### 2.2 Model-free A2 native checks

**Method.** The new test target `Tests/SpeechNativeEOUTests` (speech builds only; test-only, so the executable is
unaffected) constructs the real `StreamingSession` with three stub `MLModel` subclasses. The stubs return scripted
argmax results — a token, `<EOU>` or blank — for each (encoder chunk, frame). No Core ML model is loaded. Every
other component is the unmodified vendored code: the mel front end, chunk loop, RNNT greedy loop, EOU debounce and
`finalize()`. The configuration uses A2's real geometry: the asset `config.json` with 64 mel frames, 4 output
frames and a 10240-sample chunk shifted by 5120 samples, the profile's 1280 ms debounce, and 320-sample pushes.
Native updates are mapped by the harness's own `SpeechEOUBackend.update` into `RecordingTranscriptAccumulator`,
just as the A2 adapter does. Correct-behavior assertions are wrapped in `withKnownIssue`. Beside them,
characterization assertions pin the original behavior, so any change in the SDK fails the suite.

| Check | Result on unmodified SDK | Mechanism |
|---|---|---|
| Control: three distinct utterances | finals `yeah`, `okay`, `so`; no rollback | — |
| **F04a**: consecutive identical utterances (`yeah`, `yeah`, `so`) | **Reproduced.** Native finals `yeah`, `so`; segment 1 skipped; recording final `yeah so` | `StreamingSession.swift:374–381` advances offset/segment, then returns nil when text equals the last final |
| F04a across a silence-only EOU segment | **Reproduced.** Second `yeah` still suppressed | the empty-text EOU path does not clear `lastEmittedFinalText` |
| Control: trailing chunk without EOU | open `okay` finalized by `finalize()` | — |
| **F04b**: EOU confirmed in the padded trailing chunk | **Reproduced.** `finalize()` returns nothing; recording final is empty while `okay` stays open | `StreamingSession.swift:217–228` discards the trailing `processChunk` result, then finds no pending tokens |
| (c) Coverage after the trailing chunk (additional) | Audio after `5120 × encoder calls` is never decoded. Real loop: ES2008a 3249 calls, **3200 samples (200 ms)** undecoded; 1200 s ES2008b crop 3750 calls, 0 undecoded | `finalize()` processes one trailing chunk, which decodes only 4 output frames |
| (d) Frames after `<EOU>` in the same chunk (additional) | Never passed to the joint; a token aligned to them is never emitted | `RNNTGreedyDecoder.swift:119` breaks the frame loop on EOU |

Incidental observation, with no loss: the debounce clock advances by each chunk's full 640 ms buffer, not its
320 ms of new audio. So a 1280 ms setting confirms on the third consecutive EOU chunk.

**Can these cause transcript loss?** Yes. (a), (b) and (c) silently remove recognized or recognizable text, and
the wrapper cannot recover text the SDK never emits. (d) can remove a token if speech resumes within the same
320 ms chunk.

**Did they affect the existing A2 baseline?** Not for (a)–(c):

- Within one native segment, RNNT text only grows, and the confirming chunk adds no tokens. So in an intact A2
  trace each recording partial is a prefix of the next, and the final equals the last partial. Mechanism (a)
  breaks the prefix property; it leaves the `"yeah yeah" → "yeah so"` rollback the native test observes. Mechanism
  (b) makes the final differ from the last partial. `scripts/phase1_followup/asr_rollback_audit.py` checks both
  conditions. Its positive controls in `analysis/tests/test_phase1_followup_audit.py` use exactly the sequences
  the native tests produce.
- Audit of A2 reps 1–3 (1446 partials each): **0 rollbacks; final == last partial == `predictions.json` in all
  three** (`asr-rollback-audit.json`). A1 reps 1–3 likewise show 0 rollbacks, although A1's cumulative path is
  a different mechanism.
- (c): the undecoded 1039.68–1039.88 s contains no reference words; the last lexical word ends at 1038.31 s.
- (d): not observable in saved traces. Its contribution to A2's deletions is **unknown**.

**Source fix: not made.** Neither audited mechanism changed the saved A2 output, so the existing ES2008a A1/A2
comparison is not invalidated, and correcting the SDK would only create a new configuration that would need its
own baseline. A2 keeps its identity (`speech-parakeet-eou-120m-int8`, `p1:9aa209ac…`, binary `5f8ccfe3…`).
Recommended rule for every later A2 run (C and B): run the audit and report any detected loss alongside the
scores. A corrected-A2 identity becomes worthwhile only if (a) or (b) fires on new data, or if the owner wants a
corrected-decoder comparison.

### 2.3 Impact on existing conclusions

- Execution validity, determinism and all saved metric values: unchanged.
- A1 vs A2: still a descriptive comparison of native configurations. It is not a pure model or precision
  comparison, because A2's native session has loss edge cases (one of them unauditable).
- Throughput: the only claim withdrawn outright.
- DER/JER: remain conditional, now explicitly pending Experiment A.

## 3. Experiment A — manual alignment validation

Not started. Requires human listening by the owner; no verdict will be recorded without it.

## 4. Experiment C — accelerated replay throughput

Not started.

## 5. Experiment B — ES2008b accuracy robustness

Not started.

## 6. Comparison against the original campaign

Not applicable until C or B run. Step 0 changed interpretations only.

## 7. Remaining limitations

- Acoustic alignment unvalidated (A pending); single meeting; custom reference projections; AMI in the models'
  training data (meeting-level exposure unknown).
- A2 frame skip after `<EOU>` (d): effect unknown.
- Throughput, compute-only time, accelerator placement, energy and thermal behavior: unmeasured.
- D2-rep3 memory cause unresolved; memory is runner-process 1 s sampled data.
- Framework attribution confounded by conversions and post-processing (review F05; D not in scope).
- Stale vendor provenance record (review F09) and report-eligibility hardening (F10) not addressed (not in the
  approved scope).

## 8. Publication-ready claims (current)

| Claim | Status |
|---|---|
| Four pinned configurations each completed three fresh-process, network-denied, lossless 1x replays of one 1039.88 s AMI ES2008a headset-mix crop on an Apple M5 with 16 GiB | VERIFIED |
| Final output content was identical across repetitions; independent scoring reproduces the frozen custom-policy metrics | VERIFIED |
| All four sustained separate-model 1x replay; about 79–90 s of active adapter wall time per 1039.88 s of audio | VERIFIED (scope: paced 1x, single model per run) |
| DER/JER values and the D2 miss/false-alarm tradeoff against the word-union reference | CONDITIONAL (alignment check A pending) |
| WER/CER values under the recording-text policy | CONDITIONAL (custom policy; A2 native limitation (d) unaudited) |
| The two reviewed A2 finalization edge cases did not remove text from the reported A2 output | VERIFIED |
| Runner-process sampled memory: early plateau, peaks 12–20 s, lower late level; ranges as reported | VERIFIED (scope as labelled); cause UNSUPPORTED |

## 9. Claims that remain unsupported

Any "x faster than real time" or saturated-throughput figure (unless C measures it); word or EOU latency;
isolated cold start or model load time; model-only or total unified memory; ANE execution, energy efficiency
or absence of throttling; a winning framework; quantization-caused effects; independent-speaker or unseen-AMI
generalization; a resolved memory cause; alignment precision.

## 10. Reproducibility references

- Step 0 evidence, identities and exact commands: `evidence/phase1/followup/step0/README.md`.
- Preserved campaign binary: `evidence/phase1/followup/binaries/voicebench-5f8ccfe3`. It matches `matrix.json`;
  use it, not a rebuild, for any original-identity run.
- Native tests: `Tests/SpeechNativeEOUTests/NativeEOUFinalizationTests.swift`. Audits: `scripts/phase1_followup/`.
