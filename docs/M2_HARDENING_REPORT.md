# M2 hardening report

**Date:** 2026-10-20 · **Scope:** H1 queue concurrency, H2 audio integrity, H3 resampling edge cases. No M3–M7 work and no model integration.
**Result:** all three tasks **PASS**. Machine-readable result: `evidence/M2-hardening/checkpoint.json` (12/12 commands pass).
**Version:** `voicebench 0.2.1-phase0-m2-hardening`, analysis `0.2.1`. Same machine and toolchain as Checkpoint 1 (Apple M5, macOS 26.6.2, Swift 6.3.2 Command Line Tools, Python 3.12.14 hash-locked).

## Status by task

| Task | Status | Defects found | Evidence |
|---|---|---|---|
| H1 Bounded queue concurrency | **PASS** | None in the queue. One diagnostic added. | `xunit-h1-{1,2,3}.xml` (3 separate processes), `xunit-tsan.xml`, `swift-evidence/M2-hardening/H1/*.json` |
| H2 Audio integrity | **PASS** | 2 latent defects, fixed (D2, D3) | `xunit-h2.xml`, `swift-evidence/M2-hardening/H2/*.json` |
| H3 Resampling edge cases | **PASS** | 1 documentation error, 1 missing safeguard, 1 Swift/schema mismatch; all fixed (D4–D6) | `xunit-h3.xml`, `swift-evidence/M2-hardening/H3/*.json`, `pytest-all.xml` |
| M1–M2 regression | **PASS** | — | `xunit-all.xml` (102 Swift test functions), `pytest-all.xml` (102 cases), `regression-M1/` and `regression-M2/` checkpoints rerun on the final code (both pass) |

All counts have 0 failures and 0 skipped tests, and there are no compiler warnings.

## Existing behavior verified (no change needed)

- **Blocked-sender cancellation** removes the waiter and fails it with `CancellationError`, and its element is never delivered. When cancellation loses the race with admission, the send succeeds and the element is delivered exactly once.
- **Waiting-receiver cancellation** never loses or duplicates a value, and the remaining receivers are served in FIFO order.
- **close/fail** with many waiters: `close` wakes every waiting receiver with end-of-stream and fails every blocked sender with `closed`, without delivering their elements. `fail` wakes every waiter of either kind with the failure, and later calls throw.
- **Delivery and capacity under concurrency:** with multiple producers and consumers running concurrently, under both `block` and `drop_newest`, every accepted value is delivered exactly once. Each producer's values are dequeued in send order (checked against the queue's own strictly increasing dequeue stamps). Depth never exceeds capacity.
- **Thread Sanitizer:** 33 queue and replay tests produced no reports. Instrumentation was confirmed: the test bundle links the TSan runtime.
- **Reconstruction:** the audio delivered to the consumer is **bit-for-bit** the prepared spool, with every sample delivered exactly once. This holds for 7 fixtures × 3 frame sizes × 3 modes (realtime, accelerated 4×, step); the SHA-256 of the reconstruction equals the spool hash.
- **Partial final chunk:** 16,100 frames gives chunk 50 = `[16000, 16100)`, 100 samples, bit-exact, due at exactly 1,006,250,000 ns of media time.
- **Degenerate inputs:** a zero-length input produces no chunks and its spool hashes as empty bytes. A single-sample input produces one exact chunk. Both hold in every mode.
- **Immutability:** a first consumer that mutates its copy doesn't affect a second consumer. Chunks retained while the queue was backed up (so the producer kept reading) were still bit-exact at the end.
- **drop_newest:** delivered chunks are bit-exact at their own ranges, no delivered chunk overlaps a dropped range, and delivered ∪ dropped covers each sample exactly once (example: 12,480 delivered + 3,520 dropped = 16,000).
- **Resampling invariance:** converter output is identical for input callbacks of 1, 7, 97, 1000 and 4096 frames on 5 ratios (including non-integer ones). Impulses at exact-mapping positions peak exactly there on 8 ratios, including upsampling.

## Defects discovered and fixed

| ID | Severity | Defect | Fix | Test |
|---|---|---|---|---|
| D1 | — | No queue defect was found. The queue lacked a self-check for its structural invariants. | `BoundedQueue.invariantViolations` (DEC-030) | Asserted after every stress round |
| D2 | Medium (latent) | `FrameIterator.next()` was `try? nextChunk()`: a spool read error would have silently ended the stream early. Its `failure` property was never set. The scheduler used only the throwing path, so this was never triggered. | Removed the non-throwing path and the dead property (DEC-027) | Compile-time; all replay tests use the throwing API |
| D3 | Medium | Replay wasn't bound to the hashed spool. A spool changed on disk after preparation would have replayed as if it were the hashed audio. | The iterator hashes every produced byte, and the scheduler verifies frames and SHA-256 at end of stream (DEC-028) | `modifiedSpoolIsDetected` (step and realtime) |
| D4 | High (documentation) | DEC-018 and api-verification said the ±1 endpoint correction "was never needed". That held only for the original fixtures. | Corrected: 46 of 243 matrix cases need it (DEC-018) | `endpointMatrixIsDisclosedAndBoundedByOneFrame` |
| D5 | High | Endpoint corrections were recorded only as trim and extend counts. There was no explicit status, no strict mode, and no consistency check, so a correction could pass benchmark validation unnoticed. | `EndpointPolicy` (`allow_one_frame_v1` / `strict`), `endpoint_status`, `ConversionRecord.validate()`, `requireExactEndpoints()`. The schema forbids a correction reported as `exact` and a strict record containing one (DEC-025) | `strictPolicyRefusesExactlyTheCorrectedCases`, `inconsistentRecordsFailValidation`, corpus `invalid/runtime-summary-conversion/*`, Python `test_strict_endpoint_policy_refuses_a_corrected_conversion` |
| D6 | High (latent) | `ConversionRecord.toJSON()` emitted three keys the `runtime-summary` schema rejects, so M4's first runtime summary would have failed validation. | Schema aligned and cross-language test added (DEC-029) | `test_swift_conversion_record_validates` (6 fixtures through `voicebench dev prepare-audio`) |

While being reviewed, two of the new tests turned out to deadlock by design: they waited on blocked senders with no consumer running. They were fixed before their first run. These were test defects, not product defects.

## Measured resampling behavior (H3)

The matrix covered 9 rate pairs × 27 lengths: 0–12, then 50, 100, 101, 999–1001, 4095–4097, 22,049–22,050 and 44,099–44,101.

| Pair | Exact | Corrected | Correction |
|---|---:|---:|---|
| 48k→16k, 32k→16k, 8k→16k, 16k→48k | 26 each | 0 | — |
| 44.1k→16k | 24 | 2 | zero-extend (n = 7, 10) |
| 22.05k→16k | 18 | 8 | trim |
| 11.025k→16k | 12 | 14 | zero-extend |
| 96k→16k | 17 | 9 | zero-extend |
| 16k→44.1k | 13 | 13 | zero-extend |

Each pair also has one bypassed zero-length case. No case differed by more than one frame. Integer ratios were always exact. Boundary impulses (first and last two input samples) always peak at the floor or ceiling of the exact output position. When the exact position falls past the last output frame, the last-sample impulse keeps about half its amplitude (0.15 vs 0.30 at 48k→16k): its response is cut off where the converted stream ends. This is a characteristic, not a defect.

## Tests added

- **Swift (21 new test functions):**
  - `QueueHardeningTests` (8 functions, 10 cases): producer and consumer cancellation stress (200 rounds × 4 waiters each), cancellation vs admission race (1,000 rounds), close/fail with 6–8 waiters, concurrent multi-producer/multi-consumer under both policies, and sample-range accounting under both policies. All run under `withTimeout`.
  - `AudioIntegrityTests` (6 functions, 27 cases).
  - `ResamplingEdgeTests` (7 functions, 26 cases).
- **Python (7 new):** conversion-record schema parity on 6 fixtures, and a strict-refusal test.
- **Corpus:** +4 documents (99 total). **Fixtures:** +6 very short WAVs (1–10 frames at 44.1k, 22.05k, 96k, 11.025k and 48k), with independent count goldens. All 51 files are reproducible byte-for-byte.

Outcome counters from the final checkpoint run (they vary from run to run):

| Test | Outcomes |
|---|---|
| Admission race | 640 admitted / 360 cancelled out of 1,000 |
| Consumer cancellation | 203 cancelled-but-served / 193 cancelled-threw / 404 uncancelled-served |
| Producer cancellation | 1 cancelled-but-admitted / 395 cancelled-threw / 404 uncancelled-admitted |

In an earlier run the producer test saw 0 cancelled-but-admitted outcomes. That branch is reliably exercised by the dedicated race test, not by the multi-sender test.

## Commands executed (all via `scripts/checkpoint.py M2-hardening --out evidence/M2-hardening`)

1. `generate_fixtures.py --small --out datasets/fixtures --verify`: 51/51 reproduced.
2. `swift build`.
3. Three runs of `scripts/swift_test.sh --filter QueueHardeningTests`, each a separate process.
4. `scripts/swift_test.sh --filter AudioIntegrityTests`.
5. `scripts/swift_test.sh --filter ResamplingEdgeTests`.
6. `scripts/swift_test.sh`: the full Swift regression, 102 functions.
7. `pytest analysis/tests`: 102 cases.
8. `phase0_analysis schema-check`: 99 documents, 0 unexpected.
9. `phase0_analysis doctor`: all checks pass.
10. `scripts/swift_test.sh --sanitize=thread --filter "QueueHardeningTests|BoundedQueueTests|AudioIntegrityTests|ReplayModeTests"`: 33 tests, 0 TSan reports.

The M1 and M2 checkpoint groups were also rerun into `evidence/M2-hardening/regression-M1/` and `regression-M2/`; both pass. Full logs are in `evidence/M2-hardening/logs/`.

## Remaining risks

1. **Concurrency coverage is probabilistic.** The stress tests sample interleavings on one machine. Exactly-once is enforced by `CheckedContinuation` (a double resume traps) and by timeouts (a lost resume fails the test), but this is not a proof. TSan found no races in the exercised interleavings.
2. **Disclosure isn't enforced end-to-end yet.** Endpoint corrections are now explicit in the record and the schema, but M4 must copy `endpoint_status` into `runtime_summary.json`, and M6 `validate --run` must surface corrections. Until then, disclosure stops at the `ConversionRecord`.
3. **Zero-extension inserts a synthetic 0.0 tail sample; a trim drops the last native frame.** Both are disclosed. Whether benchmark runs should default to `strict` is an owner decision (DEC-026). The recommendation is to keep `allow_one_frame_v1` with mandatory disclosure.
4. **Spool tampering is detected at end of stream, not before consumption.** A tampered run fails, but adapters will already have processed the altered chunks.
5. **SRC counts and output are SDK-specific** (measured on SDK 26.5). Another SDK may round differently, and the matrix test would show it.
6. **The schema 1.0 conversion object changed again** (DEC-029). That relies on DEC-008 (keep 1.0 mutable until the first sealed run), which still awaits an owner decision.

## Owner decisions requested

- **DEC-026:** the default endpoint policy for benchmark runs. Recommended: `allow_one_frame_v1` with mandatory disclosure.
- **DEC-008:** confirm schema 1.0 stays mutable until the first sealed run. It has now been used for D6.
