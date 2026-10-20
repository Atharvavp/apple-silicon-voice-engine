# Phase 0 contracts (as implemented through M2 hardening)

The approved plan (sections C and D) is the design source. This page records
what the code enforces today and where. Schema files under `schemas/v1/` are
authoritative for persisted structure.

## Persisted JSON

- **One model:** `JSONValue` keeps `.int(Int64)` and `.double(Double)` separate
  and objects in insertion order (`Sources/BenchmarkSupport/JSONValue.swift`).
- **Strict parsing** (`StrictJSON`; Python `phase0_analysis.schemas.loads_strict`):
  RFC 8259 plus rejection of duplicate keys, invalid UTF-8, lone surrogates,
  integers outside int64, non-finite numbers (NaN, Infinity, 1e400), nesting
  deeper than 128, and trailing content.
- **Strict reading** (`FieldReader`): every key must be consumed. Unknown keys
  fail with a `$.path` message. Absent values are written as an explicit
  `null`, never omitted.
- **Canonical bytes** (`JSONWriter.canonical`, `settings_json_v1`): keys sorted
  by code point, compact, integers only. Only `"`, `\` and C0 controls are
  escaped (`\b \f \n \r \t`, otherwise lowercase `\u00xx`); non-ASCII, `/`, DEL
  and U+2028/2029 stay literal. Byte-identical to Python
  `json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.
- **Versioning:** every document has `schema_version: "1.0"`. Readers reject
  any other version (`SchemaVersion.check`). See DEC-008 on refining 1.0 before
  the freeze.

## Authored config (`configs/*.yaml`)

The structure is `config.schema.json#/$defs/authored`, read by `RunConfig.read`.

| Field | Rule |
|---|---|
| `audio.target_sample_rate_hz` | 1…768000 |
| `audio.downmix_policy` / `conversion_policy` | `arithmetic_mean_v1` / `apple_normal_max_half_up_v1` |
| `replay.mode` | `realtime` \| `accelerated` \| `step` |
| `replay.frame_ms` | 10 \| 20 \| 40 \| 80 and integral at the target rate |
| `replay.speed` | `{num, den}`, reduced, 1 ≤ num/den ≤ 100, required iff `accelerated`, else `null` |
| `replay.queue_capacity` | 1…4096 |
| `replay.overflow` | `block` \| `drop_newest` (no `drop_oldest` in v1) |
| `adapters.{asr,diarization}` | `{id, revision, delay_ms 0…600000}`; the two IDs must differ |
| `seed` | 0…Int64.max |
| `telemetry.interval_ms` | 100…60000 |
| `runtime` | `python_executable` locator, `cleanup_timeout_s` 1…600, `analysis_timeout_s` 1…3600, `max_output_bytes` 1 MiB…1 TiB |

Paths resolve against the YAML file's directory, with no `$ENV` or `~`
expansion. CLI overrides (`ConfigOverrides`) are applied before semantic
validation. The settings hash covers `LoadedConfig.settingsDocument()`.

## Dataset manifests and annotations

- `DatasetManifest`: `pending` manifests may have no items and null source
  fields. They pass structural validation, fail `requireReady()`, and can never
  be selected (`item(_:)` throws). `ready` manifests need items, a verified
  license statement and an annotation type. Per-item path/hash pairs are both
  set or both null. `coverage.*` must match which reference files exist.
  `reference_sha256` = SHA-256 of `"<transcript hash or ->\n<speakers hash or ->\n"`.
- Annotations (`AnnotationDocument`) keep their own `timebase` (samples at the
  source rate) and `original_precision`. Intervals are half-open with
  `0 ≤ start < end`.
  - **Transcript:** `recording` granularity has untimed text and full coverage
    only. `utterances`/`words` segments are media-ordered, non-overlapping and
    inside coverage.
  - **Speakers:** different speakers may overlap; same-speaker overlaps are
    kept as authored.
  - **Joint words:** preserved only; there's no attribution scoring.

## Events, metrics and status (envelope level)

- `EventEnvelope`: D5 fields. `media_start/end` are both null or both set with
  `start ≤ end`. `monotonic_recorded_ns ≥ monotonic_emitted_ns`, same clock.
  `virtual_emitted_ns` is step-only. The type must be one of the 18 v1
  families. Typed payload checks come in M3 (JSON Schema already checks payloads).
- `MetricRecord`: `ok` means a finite value and null reason; any other status
  means a null value and a non-empty reason.
- `RunStatus`: lifecycle `created → validated → prepared → running → flushing →
  scoring → completed`, with `failed`/`cancelled` from any nonterminal state.
  A completed status lists artifact digests; nonterminal statuses carry none.

## Audio (AudioCore)

1. `WAVInspector` checks RIFF bytes before any decoder runs. Supported:
   PCM s16/s24/s32 and Float32, mono or stereo, plain or extensible (standard
   GUID, `validBits == bits`). Everything else fails with one typed
   `AudioError.Kind`.
2. `WAVDecoder` uses AVAudioFile Float32 deinterleaved in 4,096-frame blocks.
   Float sources are checked for finiteness, and the frame count must equal the
   container's.
3. `MonoDownmixer` (`arithmetic_mean_v1`): mono passes through; stereo is
   `Float((Double(L)+Double(R))/2)`. No normalization or clipping.
4. `SampleRateConverter` (`apple_normal_max_half_up_v1`) streams through
   AVAudioConverter with Normal algorithm, Max quality and `.normal` priming,
   and drains to EOS. Intended count is
   `Nout = floor((Nin·Rout + floor(Rin/2))/Rin)`. Under `EndpointPolicy.allowOneFrame`
   (the default, `allow_one_frame_v1`), a native ±1 is trimmed or zero-extended
   at the tail. Under `strict`, any difference is a `conversionContract` error,
   and so is any difference larger than one under either policy. The same rate
   (or an empty input) bypasses SRC exactly. Every `ConversionRecord` carries
   `endpoint_policy` and `endpoint_status` and must pass `validate()`.
   `requireExactEndpoints()` is the strict benchmark check, which fails on any
   correction. Corrections are routine for non-integer ratios (DEC-018).
5. `PCMSpool`: Float32 LE, exclusive creation, SHA-256 over the bytes on disk.
   `ConversionRecord` and `AudioSourceMetadata` keep the source facts separate
   from the converted ones.

## Replay

- Chunks: `ChunkPlan` tiles `[0, N)` into `frame_samples` chunks and allows a
  final partial. `AudioChunk` holds `OwnedMonoPCM` (a private immutable copy).
- Deadlines (end-of-frame, `end_of_frame_v1`): media `floor(end·1e9/rate)`;
  accelerated `floor(end·1e9·den/(rate·num))`. Real and accelerated planned
  deadline = replay anchor + offset, one absolute sleep per chunk on the run clock.
- `BoundedQueue` (actor): FIFO; `block` suspends senders in FIFO order and
  stamps admission when space opens; `drop_newest` rejects the offered element.
  Close drains, then returns nil. Fail wakes every waiter with an error.
  Cancellation removes the waiter, so each continuation resumes exactly once.
- Timing per chunk (`ChunkRecord`): planned (real) or virtual deadline, offer,
  entry (admission), dequeue and finish. Wake error = `offer − planned`;
  delivery error = `entry − planned`.
- Integrity: `FrameIterator` hashes every byte it hands out. Each replay ends
  with `verifyAgainstSpool()`, which requires all frames produced and their
  SHA-256 equal to the prepared spool's; otherwise it throws `CoverageError`.
  Read errors always throw; there is no silent `next()`.
- Step mode: one coordinator advances `VirtualClock` to `max(now, deadline)`,
  admits, dequeues and awaits the consumer before the next chunk. It performs
  no real sleeps, and virtual stamps exist only in this mode.
- `ReplayTrace.verifyCoverage(lossless:)` checks contiguous indices and
  ranges, full-frame non-final chunks, every accepted chunk consumed in FIFO
  order, no dropped chunk ever consumed, `produced = admitted + dropped`,
  `consumed = admitted`, and `maxDepth ≤ capacity`. When `lossless` is set,
  drops are forbidden. `droppedRanges` is the merged union.
