## Known limitations

1. **Mock-only scope.** Both adapters are deterministic scripted mocks. WER/CER/DER/JER on the synthetic items prove
   the scorers and the pipeline joins, never recognition or diarization quality.
2. **Uncontrolled performance host.** P01–P03 ran from an agent session on the developer's Apple M5 machine with
   no control over other processes, power source or thermal state (load averages and power source are recorded per
   run in `performance/characterization.json`). Treat the timing numbers as a provisional characterization of this
   host. Re-run `scripts/characterize.py` on a controlled idle machine before relying on them for Phase 1
   comparisons.
3. **Tested environment only.** macOS 26.6.2 (25G83), Swift 6.3.2 Command Line Tools, SDK 26.5, Python 3.12.14 from
   the hash lock. The macOS 13 deployment floor is compiled, not executed; other macOS or Python versions are
   untested. Swift tests need `scripts/swift_test.sh` because only the Command Line Tools are installed (DEC-003).
4. **SRC results are SDK-specific.** Converted audio hashes and the ±1-frame endpoint behavior were measured on SDK
   26.5; another SDK may differ. Corrections are always disclosed (DEC-025/026); `strict` refuses them.
5. **Telemetry coverage.** CPU and current RSS are runner-process counters. The RSS peak is a sampled peak, not the
   lifetime high-water mark. GPU, ANE and power are `unsupported`; thermal state is the OS enum with its
   "nominal may mean unsupported" caveat. The Python analysis process is not measured.
6. **Offline proof mechanism.** V19 relies on `sandbox-exec`, which Apple marks deprecated; it was verified
   functional on this host with positive and negative controls. Initial dependency installation still needs the
   network (setup only).
7. **Concurrency verification is empirical.** Exactly-once queue semantics are enforced by `CheckedContinuation`
   traps and wall-clock-bounded tests, and Thread Sanitizer found no races in the exercised interleavings; this is
   not a proof.
8. **Spool tampering after preparation** is caught before replay (re-hash on disk) and at end of stream (hash of
   the replayed bytes); a modification *during* replay is detected at end of stream, after adapters consumed it,
   and the run then fails rather than being sealed.

## Deviations from the plan's letter (all recorded in `docs/decisions.md`)

- DEC-001: repository location is this existing repo, not the plan's proposed client path.
- DEC-002: the plan and planning pack are not copied into the repo; the planning pack directory was not readable
  from the execution session, so the plan (which embeds the locked decisions and traceability) was the source.
- DEC-003: Swift Testing instead of XCTest (Command Line Tools only).
- DEC-011: `seed` limited to int64.
- DEC-033/034: new `adapter.diagnostic` event family and `fixture-script` document type (schema 1.0 refinements
  inside the DEC-008 window, before the freeze).
- DEC-035: `audio.endpoint_policy` added to the authored config so DEC-026's strict policy is selectable per run.
- DEC-070: usage errors exit 2 instead of ArgumentParser's default 64, to match plan G3.

No locked requirement (Q1–Q18, D1–D5) was changed and no change request was needed.

## Owner decisions applied

- DEC-026 (approved): `allow_one_frame_v1` default with mandatory disclosure; `strict` retained and enforced.
- DEC-008 (approved): schema 1.0 refined through M6, frozen before the first sealed benchmark run
  (`schemas/SCHEMA_BUNDLE_V1.sha256`); every sealed run records the bundle digest and `frozen: true`.
- Spool integrity: pre-replay re-hash on disk plus end-of-stream verification; either failure fails the run.

## Phase 1 prerequisites

1. **Owner approval to start Phase 1**; nothing in this report authorizes real model integration.
2. **Gate B datasets:** select English and Hindi sources (10–20 min each), verify licenses and redistribution
   terms from primary sources, record coverage, granularity and hashes, and move the manifests from `pending` to
   `ready`. Until then Phase 1 can only run synthetic inputs.
3. **Controlled performance host:** re-run P01–P03 on an idle, plugged-in target machine (fanless M5 MacBook Air,
   16 GB) and record the conditions, before any latency or resource ranking.
4. **Adapter work per `docs/phase1-adapter-guide.md`:** one role per adapter, real capabilities, observed placement
   only from a real probe, outputs only through the sink, the same contract/failure suites.
5. **Designs still needed before they are used:** clock synchronization for any backend timestamps from another
   process or device; any active-compute-time measurement; any IPC adapter transport.
6. **Project license:** choose the project's redistribution license and add the upstream libyaml notice before any
   binary or fixture redistribution.
7. **Schema evolution:** any new event or field for real adapters (e.g. word timings beyond the current payloads)
   requires a new schema version, since 1.0 is frozen.
