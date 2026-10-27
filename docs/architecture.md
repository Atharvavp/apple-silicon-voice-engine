# Architecture

This page explains how audio moves through the harness and which component owns which state.
Field-level rules are in [contracts.md](contracts.md) and `schemas/v1/`. Metric definitions are in
[benchmarking.md](benchmarking.md).

## Scope

One `voicebench run` process runs **one experiment**: one dataset item, one audio stream, one ASR
adapter and one diarization adapter. It replays a prerecorded WAV file. There is no microphone path,
no long-lived service and no IPC API. In the default build both adapters are scripted mocks. In the
optional builds, one role at a time can be a real FluidAudio or speech-swift wrapper, while the
other role is a passive adapter that loads and emits nothing.

## Modules

```text
BenchmarkSupport  <- AudioCore <- Replay
BenchmarkSupport, AudioCore <- AdapterContracts <- MockAdapters
CTelemetry (C shim) <- Telemetry
all of the above <- Experiment <- BenchmarkCLI
AdapterContracts <- RealAdapterSupport <- FluidAudioAdapters / SpeechSwiftAdapters <- BenchmarkCLI
```

| Module | Responsibility |
|---|---|
| `BenchmarkSupport` | `JSONValue` model, strict JSON and YAML, run config, dataset manifests, annotations, event envelopes and typed payload checks, metric records, the run clock |
| `AudioCore` | RIFF inspection, AVAudioFile decode, `arithmetic_mean_v1` downmix, AVAudioConverter resampling with an explicit endpoint policy, the hashed PCM spool, sample/time arithmetic |
| `Replay` | Frame iterator, replay scheduler (realtime, accelerated, step), bounded queue, virtual clock, replay trace and coverage checks |
| `AdapterContracts` | `ASRAdapter` / `DiarizationAdapter` protocols, capabilities, the event sink, output validation |
| `MockAdapters` | Deterministic scripted mocks driven by fixture scripts |
| `CTelemetry`, `Telemetry` | `getrusage` CPU time, `task_info` resident size and footprint, compile-time SDK facts, the ~1 Hz sampler |
| `Experiment` | Run plan and preflight, pipeline worker, event recorder, lifecycle and failure handling, environment capture, the Python bridge, sealing |
| `RealAdapterSupport` | Shared, model-free wrapper logic: model profiles, passive adapters, streaming wrappers, output helpers. It is always compiled and is tested with fake backends |
| `FluidAudioAdapters`, `SpeechSwiftAdapters` | Thin wrappers over the pinned SDKs. They are compiled only when `PHASE1_FRAMEWORKS` selects them |
| `BenchmarkCLI` | `voicebench run / validate / compare / export` and hidden `dev` helpers used by the parity tests |

`PHASE1_FRAMEWORKS` (`none` by default, or `fluid`, `speech`, `both`) is read by `Package.swift`.
It decides which SDKs are resolved and linked and which adapter IDs the factory registers. It also
raises the platform floor: macOS 13, 14 or 15.

## Data path

1. **Preflight** (`RunPlan`). Strict YAML loading, CLI overrides, semantic validation, manifest and
   reference hashes, adapter IDs. Nothing is written before the config is valid. The run directory
   is created exclusively and is never reused.
2. **Audio preparation** (`AudioCore`). `WAVInspector` checks the container bytes before decoding.
   Decoding uses Float32 in 4,096-frame blocks, then explicit downmix, then resampling to the target
   rate (16 kHz in the shipped configs). The intended converted length is
   `floor((Nin·Rout + floor(Rin/2)) / Rin)`. A native ±1-frame tail difference is corrected under
   `allow_one_frame_v1` and **disclosed**, or refused under `strict`. Same-rate input bypasses
   conversion. The result is a Float32 mono spool on disk with its SHA-256, which is verified again
   before replay.
3. **Chunking** (`FrameIterator`). The spool is cut into integer-sample frames (10/20/40/80 ms; the
   last chunk may be partial). The iterator hashes every byte it hands out, and the replay must end
   with `verifyAgainstSpool()`.
4. **Replay** (`ReplayScheduler`).
   - `realtime` / `accelerated`: one producer sleeps to absolute deadlines
     `anchor + offset(end_sample)` on one run clock. The offset is scaled by a rational speed in
     accelerated mode. Deadlines are never reset, rushed or skipped. One consumer receives in FIFO
     order.
   - `step`: a single coordinator advances a separate virtual clock to each chunk's media deadline,
     admits the chunk, dequeues it and awaits the consumer before the next chunk. Nothing sleeps.
     Virtual time is deterministic and is not latency.
5. **Queue** (`BoundedQueue`, an actor). Capacity 1–4096. `block` suspends the producer in FIFO
   order. `drop_newest` rejects the offered chunk, and the dropped sample range is recorded. Close,
   fail and cancellation each resume every waiter exactly once.
6. **Worker** (`Pipeline`). For each delivered chunk it calls `asr.consume` and then
   `diarization.consume`, in that fixed order, and emits a `stage.completed` per call and an
   `audio.chunk_consumed` per chunk. After the last chunk the runner calls `flush` on each adapter,
   then `shutdown`.
7. **Recording** (`EventRecorder`). Adapters never choose sequence numbers or timestamps. They
   report through a sink, and the recorder validates each event (envelope and typed payload), stamps
   it and writes it through a bounded JSONL queue with byte limits (`max_output_bytes`). Telemetry
   samples go to `telemetry.jsonl` through their own bounded stream.
8. **Scoring and sealing**. The runner freezes the runtime artifacts, then calls
   `python -m phase0_analysis score` with the interpreter and project root frozen in `config.json`
   and an explicit, minimal environment. Python builds `metrics.json` and the initial
   `validation.json`. The runner writes `status.json` as `completed` with the SHA-256 of every
   artifact. Any earlier failure ends the run as `failed` or `cancelled`, with partial artifacts
   kept and labelled.

Lifecycle: `created → validated → prepared → running → flushing → scoring → completed`, with
`failed` or `cancelled` possible from any nonterminal state. SIGINT/SIGTERM cancel a run, which then
ends `cancelled` with exit code 130.

## Clocks

| Clock | Used for | Never mixed with |
|---|---|---|
| Run clock (`ContinuousRunClock`, ns since one process-local origin) | All real timestamps: deadlines, offer/admission/dequeue/finish, stage durations, event emission | Virtual time |
| Virtual clock (step mode only) | Media deadlines and delivery stamps that reproduce exactly across runs | Real latency |
| Media time (samples) | Chunk boundaries, predictions, references, coverage | Wall time |

## What is bounded and what is not

| Bounded | Not bounded by that alone |
|---|---|
| Audio queue (capacity, block or drop) | Total run memory: adapters keep their own state, and real models allocate freely |
| Event and telemetry write queues (block when full) | The event trace on disk, which is limited only by `max_output_bytes` |
| FluidAudio ASR callback mailbox (drained after each awaited call) | Diarization wrappers, which keep the whole finalized timeline until flush |
| One frame of endpoint correction under `allow_one_frame_v1` | Retained predictions and transcript text, which grow with the recording |

## Real adapters

Real wrappers implement the same protocols as the mocks. They load only files listed in a hashed
model profile, and a profile whose embedded geometry differs from the expected one fails at
`prepare`. Diarization output is **final-only**: audio feeds the native streaming state during
`consume`, and the complete timeline is emitted once at `flush`. ASR output is recording-level text
with genuine partials and exactly one final, with no media times. Native SDK behavior is reported as
found and is not patched over. For example, the speech-swift EOU session has documented finalization
edge cases. See the [Phase 1 guide](phase1/README.md) and the [adapter guide](phase1-adapter-guide.md).

## Python boundary

The `analysis/` package (`phase0_analysis`) does schema validation, scoring, comparison, export and
the environment doctor. It never runs models: the doctor fails if a model, inference or hub-download
package is installed. Swift calls it as a child process with a fixed environment (`PYTHONPATH`,
no inherited `HOME`). The same module can be called directly to validate a copied run read-only:

```sh
PYTHONPATH="$PWD/analysis/src" .venv/bin/python -m phase0_analysis validate \
    --run <run-dir> --schemas schemas/v1 --out <new-report.json>
```
