# Benchmarking methodology

This page defines what a run measures, what makes a run valid, and when two runs can be compared.
Numbers from the one historical real-model campaign are in [phase1/PHASE_1_RESULTS.md](phase1/PHASE_1_RESULTS.md).
How audio flows is described in [architecture.md](architecture.md).

## Two kinds of validity

| | Means | Established by |
|---|---|---|
| **Execution validity** | The run did what the config says. Every sample was produced, admitted and consumed (or every drop was recorded), events are well formed, artifacts are intact and the run sealed `completed` | `status.json`, `runtime_summary.json` coverage, `validation.json` (`pass`), `voicebench validate --run` |
| **Scientific validity** | The numbers mean what you want them to mean: references are correct and aligned, the conditions are comparable, and the sample is large enough | Not automatic. It needs reference checks (for example a listening check), matched configurations and more than one recording |

A sealed, validated run has execution validity only. `COMPLETE` in a generated report certifies
the measurement process, not the reference data.

## Replay and time

- **Media time** is measured in samples. Chunk deadlines use the end-of-frame convention
  (`end_of_frame_v1`): media deadline `floor(end_sample · 1e9 / rate)` ns. In accelerated mode it is
  scaled by a rational speed.
- **`realtime` and `accelerated`** pace chunks to absolute deadlines on the run clock. Timing
  metrics in these modes are wall-clock observations on that host.
- **`step`** uses a virtual clock and waits for each consumer before the next chunk. It is
  deterministic and suited to correctness work. Its "latencies" are virtual and are excluded from
  latency comparisons.
- **Warm-up**: scheduling-error metrics have a post-warm-up variant that excludes the first 10 s of
  media (DEC-061).

## Accuracy metrics

| Metric | Policy | Definition |
|---|---|---|
| WER, CER | `nfc_casefold_punct_space_cp_v1` | NFC and casefold, every Unicode punctuation character becomes a space, whitespace collapses, symbols and scripts are kept. WER units are space-delimited tokens and CER units are Unicode code points with whitespace removed (jiwer 4.0.0 edit counts). An empty reference is `not_computable`, never 0 or 1 |
| DER, JER | `pyannote_c0_overlap_uem_v1` | pyannote.metrics 4.2.0, collar 0, overlap scored, explicit UEM over the replayed media, optimal speaker mapping. A zero denominator is `not_computable` |

Hand-derived goldens (`testdata/goldens/`) fix the arithmetic. Python and Swift parity tests check
that both sides agree on artifacts. Metric and normalizer definitions belong to the frozen v1
contract and are not changed in place.

**Reference caveat.** The real-model campaign used project-built references from the AMI manual
annotations. The transcript reference is recording-level text, a mono overlap linearization
(`ami_nxt_recording_text_v1`). The speaker reference is the union of timed word intervals
(`derived_word_union_v1`). Neither is the standard AMI evaluation, so neither can be compared with
published AMI numbers.

## Timing metrics

| Metric | Definition | Not |
|---|---|---|
| `adapter_service_rtf` | Sum of the wall durations of every `consume` and `flush` call (both roles) ÷ audio duration. It includes awaited backend work, sample handling, transcript assembly and sink waits | Compute-only time. Under paced replay its inverse is **not** throughput or "x faster than real time" |
| `replay_rtf` | Replay anchor → runtime drain end, ÷ audio duration | A speed measure under 1× pacing: it is ≈1 whenever processing keeps up |
| `end_to_end_rtf` | Setup start → runtime drain end (scoring excluded), ÷ audio duration | Same |
| `media_seconds_per_second` | Consumed media seconds ÷ replay elapsed | Saturated throughput under paced replay. Only an unpaced/accelerated design measures that, and none was run with real models |
| `processing_lag_ns` | Chunk-consumption finish − that chunk's planned deadline | End-to-end latency to a user |
| `event_emission_latency_ns` | Output event emission − start of the invocation that caused it | Word or end-of-utterance latency |
| `delivery_to_output_latency_ns` | Output event emission − admission of its cause chunk | Same. With recording-level ASR and final-only diarization it has no word-level meaning |
| `scheduler_wake_error_ns`, `delivery_jitter_ns` | Offer − planned deadline; admission − planned deadline | — |
| `time_to_first_word_ns`, `compute_only_rtf` | Always `not_computable`: no adapter exposes word timing or active compute time | — |

Percentiles use nearest rank within one run. Summaries across runs report the median [min, max]
of per-run values and never pool percentiles.

## Resource metrics

`telemetry.jsonl` samples **the runner process** about once per second: CPU time (`getrusage`),
`resident_size` and `phys_footprint` (`task_info`). The peaks are sampled maxima, and short
peaks can be missed. These values are not model-only memory, total unified memory or a process-tree
peak. GPU, ANE, power, energy and thermal behavior are not measured (thermal state is recorded as
reported, and "nominal" can also mean unsupported). `prepare` covers profile and asset verification
plus backend load, so it is not an isolated cold start.

## Comparing runs

`voicebench compare --runs A B … --profile accuracy|latency|resources --out NEW_DIR` lists field-by-field
reasons for every difference. A reason either blocks ranking or is only disclosed. Ranking happens
only between compatible runs whose primary metric is `ok`. Failed, unsealed or invalid runs block
ranking, and so do lossy runs (for accuracy), step-mode latency and unverified hardware.
`--allow-noncomparable` prints labelled side-by-side rows and never ranks.

A comparison tool cannot see the confounds that matter most for framework studies: different model
conversions, precision, post-processing and native decoder behavior. Note them yourself and do not
attribute differences to a framework, precision or accelerator unless the configurations are matched.

## Workflows

| Goal | Entry point |
|---|---|
| First mock run | `bash scripts/setup.sh && bash scripts/smoke.sh` ([README](../README.md#quick-start-mock-adapters)) |
| Your own mock experiments | Copy a file in `configs/`, then `voicebench run / validate / export / compare` ([cli.md](cli.md)) |
| A new adapter | [phase1-adapter-guide.md](phase1-adapter-guide.md) |
| Real-model campaign | [phase1/README.md](phase1/README.md) |
| Historical Phase 0 acceptance and characterization | `scripts/checkpoint.py`, `acceptance.py`, `characterize.py`, `determinism.py`, `offline_smoke.sh` ([development.md](development.md)) |
