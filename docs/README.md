# Documentation

## Current references

| Document | Covers |
|---|---|
| [../README.md](../README.md) | Scope, quick start, results context |
| [architecture.md](architecture.md) | Modules, data path, clocks, lifecycle, what is and is not bounded |
| [benchmarking.md](benchmarking.md) | Validity, replay/time definitions, metric definitions, comparability |
| [cli.md](cli.md) | `voicebench` commands, behavior, exit codes |
| [contracts.md](contracts.md) | Invariants the code enforces: JSON/YAML strictness, events, audio, replay |
| [phase1-adapter-guide.md](phase1-adapter-guide.md) | How to add a real ASR or diarization adapter |
| [phase1/README.md](phase1/README.md) | Optional real-model setup: assets, licenses, SDK build, smoke, measured campaign |
| [phase1/PHASE_1_RESULTS.md](phase1/PHASE_1_RESULTS.md) | **Canonical** results of campaign 20261021-s2, with corrections |
| [phase1/evidence/20261021-s2/](phase1/evidence/20261021-s2/README.md) | Public evidence packet: aggregates, identities, per-run record |
| [phase1/PHASE_1_FOLLOWUP_RESULTS.md](phase1/PHASE_1_FOLLOWUP_RESULTS.md) | Follow-up checks after the independent review (A2 native edge cases, memory, DER shift) |
| [development.md](development.md) | Check matrix, CI scope, optional SDK builds, change rules |
| [dependencies.md](dependencies.md) | Lock files, pins and declared licenses ([../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) for scope) |
| [api-verification.md](api-verification.md) | Platform and library behavior the code relies on, and how each was verified |
| [roadmap.md](roadmap.md) | Implemented, pending and planned work |

## Historical records (dated; not current status)

These records are kept as evidence. They describe the project at the time they were written.
Statements of readiness or approval in them are not current publication status or authorization.

| Record | Date | Notes |
|---|---|---|
| [../PHASE_0_READINESS_REPORT.md](../PHASE_0_READINESS_REPORT.md) | 2026-10-20 | Phase 0 "Gate A" PASS for the **mock-only** harness. It was generated from `evidence/M7` and is kept byte-identical |
| [readiness-narrative.md](readiness-narrative.md) | 2026-10-20 | Input to the readiness report generator |
| [M2_HARDENING_REPORT.md](M2_HARDENING_REPORT.md) | 2026-10-20 | Queue concurrency, audio integrity and resampling hardening |
| [implementation-log.md](implementation-log.md), [decisions.md](decisions.md) | 2026-10-20 → | Milestone log and decision register (`DEC-*` IDs are referenced from code and docs) |
| [phase1/history/PHASE_1_RESULTS-20261021-s1-NOT_RUN.md](phase1/history/PHASE_1_RESULTS-20261021-s1-NOT_RUN.md) | 2026-10-21 | Session s1: builds and model-free tests only |
| [phase1/history/PHASE_1_RESULTS-20261021-s2-pre-review.md](phase1/history/PHASE_1_RESULTS-20261021-s2-pre-review.md) | 2026-10-21 | **Superseded** s2 wording, including the withdrawn "11–13x faster than real time" claim |
| [phase1/CODEX_INDEPENDENT_REVIEW.md](phase1/CODEX_INDEPENDENT_REVIEW.md) | 2026-10-26 | Independent review that led to the corrections |
| [phase1/PHASE_1_FOLLOWUP_PLAN.md](phase1/PHASE_1_FOLLOWUP_PLAN.md) | 2026-10-26 | Follow-up plan. Only Step 0 has been executed |
| [publication/](publication/) | 2026-10-27 | Publication audit, plan, checklist and verification report |

Some historical records cite git-ignored paths under `evidence/` that exist only on the
author's machine. The public subset of the Phase 1 evidence is the packet linked above.
