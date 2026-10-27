# Roadmap

No dates are promised. Items move between sections only with evidence.

## Implemented

- The benchmark harness: WAV preparation with disclosed endpoint policy, a hashed spool, three
  replay modes, a bounded queue with block or drop_newest, the fixed ASR-then-diarization worker,
  a validated event recorder, runner-process telemetry, sealed run artifacts, and strict schema v1
  (frozen).
- Python analysis: validation, WER/CER/DER/JER, comparison with compatibility rules, CSV/PNG
  export, the environment doctor.
- Deterministic mock adapters and the Phase 0 acceptance suite (V01–V20, mock-only).
- Four optional real wrappers (FluidAudio and speech-swift; Sortformer diarization, Parakeet EOU
  ASR), with model-free contract tests.
- One historical campaign (20261021-s2): 12 runs, one active role per run, 1× paced replay,
  corrected interpretation, public evidence packet.
- Beginner setup and smoke scripts, safe-output scripts, scoped CI definition.

## Pending (needed before stronger claims)

- **Manual alignment check** of the AMI references (follow-up Experiment A). Until it is done,
  accuracy stays conditional.
- Follow-up Experiments C (accelerated replay) and B (a second meeting). The owner approved them as
  separate steps, and neither has been run.
- First successful runs of the CI workflow on GitHub.
- Owner-selected vulnerability-reporting route ([SECURITY.md](../SECURITY.md)).

## Planned (not started)

- An integrated voice engine that runs ASR and diarization together on one stream.
- Live microphone input, a standalone VAD stage, a service or IPC API.
- Word-level timing, end-of-utterance latency, and online (revisable) speaker labels. These need a
  new, versioned event and schema design.
- Throughput characterization (unpaced/accelerated real-model runs), accelerator placement and
  power measurement with appropriate tools.
- More recordings, speakers, languages and hosts; matched-configuration framework comparisons.

## Not planned

- Silent changes to frozen schemas, metric definitions or historical campaign identities.
