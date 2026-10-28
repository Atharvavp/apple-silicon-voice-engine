# Phase 1 adapter guide

How to add a real ASR or diarization framework to the harness. It describes
the contract as implemented (`Sources/AdapterContracts`), not a new design. The
four Phase 1 wrappers (`Sources/FluidAudioAdapters`, `Sources/SpeechSwiftAdapters`,
shared logic in `Sources/RealAdapterSupport`) are worked examples.

## 1. Implement one role per adapter

- Conform to `ASRAdapter` **or** `DiarizationAdapter` (`StreamingAdapter`). An
  adapter never advertises both roles; a joint model is wrapped as two adapters
  or needs a contract change first.
- `prepare(context:sink:)` returns `AdapterCapabilities` before replay:
  accepted `sample_rates_hz` (v1 streams are 16 kHz mono by default), `channels`
  (1), `frame_multiple_samples` (or null), `incremental`, `emits_partials`,
  `emits_finals`, `transcript_granularity` (ASR: `utterances`, `words` or
  `recording`; null for diarization), `requested_placement`, and
  `observed_placement` as a `FactObservation` (`unavailable` unless the backend
  really reports where it ran). The runner rejects incompatible rates, channels
  or frame sizes before replay (exit 5).
- Use `AdapterLifecycle` to reject out-of-order calls. Call order: `prepare` once,
  `consume` per accepted chunk in order, `flush` once, `shutdown` exactly once
  (also after a failed `prepare` or a cancellation). `shutdown` must be idempotent
  and return `pending_tasks: 0`; an `error` report fails the run.

## 2. Audio and time

- `AudioChunk.samples` is an immutable private copy; never keep or mutate a
  pointer into it. Chunks join their timing (`ConsumeContext`) by
  `(run_id, stream_id, chunk_index)`.
- Host timing uses only the run clock in `AdapterContext.clock`. Timestamps from
  another process or device (GPU, ANE, a server) must not be subtracted from
  run-clock values; that needs an explicit clock-synchronization design first.
- Model latency is not the delivery latency the harness measures. If the backend
  can report active compute time, add it as a separately named field; until then
  `compute_only_rtf` stays `not_computable`.

## 3. Output only through the sink

- Emit `AdapterEvent`s: `transcript` (partial/final with an increasing `revision`
  per utterance, at most one final, nothing after it), `speakerSegment`, or
  `diagnostic`. Media ranges are integer samples at the stream rate, within the
  stream. Timed transcripts carry a range; `recording` granularity transcripts
  carry none and cannot feed media-linked latency metrics.
- Name the cause: `.chunk(index, invocationID)` from `consume`, `.flush(invocationID)`
  from `flush`. Out-of-order *emission* is allowed; invalid revision transitions
  fail the run (exit 5).
- `emit` may suspend (bounded recorder). Propagate its errors. Never write
  private files, choose event sequences, or spoof timestamps.
- `flush` must not return until every output has been emitted (join any internal
  tasks first).

## 4. Register and freeze provenance

- Add the adapter to an `AdapterFactory` entry (`role`, `requestedPlacement`,
  `isMock: false`). No other runner change is needed: `RunnerExtensionTests` and
  `ExtensionSmokeTests` prove substitution.
- Record framework, model, revision, quantization, warm-up policy and requested
  placement in the adapter's `revision` and capabilities, and the configured
  `notes.warm_state`. Do not infer ANE/GPU placement from the architecture.
- Any new telemetry must come from a proven public source and name its scope;
  unsupported counters stay `unsupported`, never zero.

## 5. Validate before comparing

- Run the same suites against the new adapter: lifecycle, output contract,
  continuity, failure injection (`AdapterContractTests`, `ExperimentTests`), and the
  e2e script. Synthetic fixture expectations do not validate recognition quality.
- Accuracy needs Gate B: verified English and Hindi subsets with recorded rights,
  hashes and annotation granularity, scored under the same frozen text and
  diarization policies. Report English and Hindi separately.
- Comparisons declare `controlled` (matched pipelines and constraints) or
  `best_practical` (different complete stacks) mode; never infer a framework-only
  causal result from best-practical runs.

## 6. Boundaries that stay in force

- One experiment per process. No IPC adapters, brokers, services, microphone, UI
  or cloud APIs until a transport and clock-sync design is approved.
- Phase 2 items (word-level speaker attribution, speaker revision metrics) are out
  of scope.
- Schema 1.0 is frozen (`schemas/SCHEMA_BUNDLE_V1.sha256`). New event types or
  fields need a new schema version and an explicit reader change.
