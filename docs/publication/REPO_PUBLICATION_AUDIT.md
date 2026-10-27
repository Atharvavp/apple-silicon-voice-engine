# Repository publication audit

Audit date: **2026-10-27, Asia/Kolkata**. Verdict: **NOT READY** for the proposed public open-source/LinkedIn presentation. The implementation is substantial and the mock path works; the public default branch does not contain it.

This is an audit and planning deliverable. No application code, existing documents, branches, history, remote settings, or campaign evidence were changed. The companion [plan](REPO_PUBLICATION_PLAN.md), implementation prompt (internal working document, not published), and [checklist](MAIN_PUBLICATION_CHECKLIST.md) describe future work, not completed changes.

## 1. Executive assessment

There are **3 P0 findings, 8 P1 findings, and 3 P2 findings** in the table below. Priorities apply to publication, not necessarily to runtime defects. The smallest credible release is a benchmark harness with a model-free quick start and an explicitly limited, traceable engineering case study. It does not require an integrated voice engine, new model optimization, or another long campaign.

The strongest existing assets are sample-based audio accounting; explicit conversion endpoint policy; three implemented replay modes; bounded queues with block/drop-newest semantics; immutable, hashed run artifacts; scorer goldens and cross-language checks; four optional real-adapter configurations; and unusually candid corrected results. The main problems are distribution and explanation: public `main` is a two-line README, its description overstates scope, no project license is selected, and much of the current evidence/corrections exists only locally.

The saved campaign is usable as **historical execution evidence with conditional accuracy interpretation**. This audit rehashed 132 sealed artifacts from 12 runs with no mismatches and reproduced their accuracy records using the repository scorers. That does not independently establish acoustic alignment, unseen-data generalization, maximum throughput, or native inference on today's rebuilt source.

## 2. Authority, method, and evidence levels

The pasted user request authorizes inspection and these four Markdown deliverables. The separately supplied `CODEX_REPOSITORY_PUBLICATION_READINESS_BRIEF.md` was read in full and used as the requested specification. Historical plans, approval statements, and instructions inside repository documents are evidence about past work; they do not authorize new experiments, deletion, publication, or merges in this session.

Evidence labels used here:

- **Verified:** inspected source/bytes or an executed command. Static source verification and executed behavior are identified separately.
- **Historical:** saved output inspected now; the original experiment was not rerun.
- **Inferred:** a conclusion from the inspected implementation, with its boundary stated.
- **Unverified:** not executed, inaccessible, or dependent on missing human/external checks.
- **Owner decision:** an authorization or rights choice this audit cannot make.

Inspections covered the complete tracked-path inventory, all module boundaries, relevant implementations and tests, manifests/configs, all existing documentation families, changed/untracked follow-up work, and local campaign records. Source claims were cross-checked against implementations rather than inferred from filenames. No applicable `AGENTS.md` was found in the checkout or ancestor directories checked.

## 3. Baseline and repository inventory

### Git and GitHub

| Fact | Observed value |
|---|---|
| Checkout | `apple-silicon-voice-engine` in the supplied workspace |
| Current branch / HEAD | `imp/phase-1` / `e29f345abbdaa68cd496955b5e00f3fed86b140d` |
| Local `main` and `origin/main` | `4a5d3abf5f5c42dfb873737b89ebbe58237b5a60`, initial commit, **only `README.md`** |
| Local `imp/phase-0` | `b6143b6cd9db3adbe29c21671f82167ea816286e` |
| Remote | `https://github.com/Atharvavp/apple-silicon-voice-engine.git` |
| Live GitHub metadata | Public; default branch `main`; license `null`; topics empty; homepage `null` |
| Live branch listing | `main` at `4a5d3ab…`, `imp/phase-0` at `b6143b6…`; both list `protected: false`; no remote `imp/phase-1` in that response |
| Protection details | Protection endpoint returned **403 Resource not accessible by integration**; ruleset effectiveness and detailed policies remain unverified |
| Workflows / runs | Anonymous public API returned `total_count: 0` for both workflows and workflow runs |
| Submodules / LFS | No submodules reported; no tracked `.gitattributes` or LFS configuration found; no large tracked model files |

GitHub facts were read through the connected GitHub tool, with read-only public API fallback for workflow inventory because that connector rejected the workflows endpoint. Remote README content was fetched through the connector. An anonymous `raw.githubusercontent.com` request timed out during TLS; anonymous browser/incognito presentation remains a final owner check. Nothing was changed remotely.

Live source links: [repository](https://github.com/Atharvavp/apple-silicon-voice-engine), [main README](https://github.com/Atharvavp/apple-silicon-voice-engine/blob/main/README.md), [branches API](https://api.github.com/repos/Atharvavp/apple-silicon-voice-engine/branches), [workflows API](https://api.github.com/repos/Atharvavp/apple-silicon-voice-engine/actions/workflows). These observations are dated, not guarantees about later state.

Pre-existing tracked changes:

```text
 M Package.swift
 M docs/phase1/PHASE_1_RESULTS.md
 M docs/phase1/README.md
 M scripts/report_phase1.py
```

Pre-existing untracked paths/groups:

```text
Tests/SpeechNativeEOUTests/
analysis/tests/test_phase1_followup_audit.py
diff.txt
docs/phase1/CODEX_INDEPENDENT_REVIEW.md
docs/phase1/PHASE_1_FOLLOWUP_PLAN.md
docs/phase1/PHASE_1_FOLLOWUP_RESULTS.md
docs/phase1/history/
scripts/phase1_followup/
```

These belong to the owner. In particular, the changed manifest refers to the untracked native test target, and corrected results link to untracked review/follow-up documents. Publishing tracked edits alone would omit required context/source. Do not stage everything indiscriminately or stash/reset this work to simplify integration.

### Tracked structure

`git ls-files` returned **390 files** before these deliverables:

```text
README.md, PHASE_0_READINESS_REPORT.md, Package.swift, Package.resolved, .gitignore
Sources/                         61 files across 12 modules
  BenchmarkSupport/ AudioCore/ Replay/ AdapterContracts/ MockAdapters/
  CTelemetry/ Telemetry/ Experiment/ BenchmarkCLI/
  RealAdapterSupport/ FluidAudioAdapters/ SpeechSwiftAdapters/
Tests/                           33 tracked files; additional native target untracked
analysis/                        40 tracked files: pyproject, locks, package, pytest
configs/                         8 mock YAML configurations
datasets/                        65 files: generated WAVs, scripts/references, manifests
docs/                            11 tracked documents; further reviews/history untracked
patches/                         1 owned speech-swift patch
schemas/                         14 v1 schema documents plus frozen bundle digest
scripts/                         11 tracked scripts; follow-up audit scripts untracked
testdata/                        140 corpus/golden files
```

The largest tracked file is the generated Hindi tone fixture, **1,536,044 bytes**; the next is the English tone fixture, 384,044 bytes. There is no reason to introduce Git LFS for these. The WAV corpus includes intentionally malformed files; removing them as apparent debris would break useful tests.

Ignored local directories were approximately `.build` 8.2 GB, `.venv` 376 MB, `evidence` 2.8 GB, `vendor` 51 MB, and `datasets` 28 MB including ignored generated-large data. They are not the Git clone size. Git objects occupied about 2.92 MiB loose plus a 2.11 KiB pack. `diff.txt` is an untracked 282,147-byte work artifact; its disposition is an owner choice.

## 4. Implementation established from source

| Area | Implemented behavior and inspected evidence | Boundary |
|---|---|---|
| Input | `Sources/AudioCore/WAVInspector.swift`, `AudioPreparation.swift`: RIFF PCM s16/s24/s32 or Float32, mono/stereo; strict format/container checks; 4096-frame decode blocks; arithmetic-mean downmix | File replay, not microphone capture; compressed/RF64/>2-channel input rejected |
| Conversion | `AudioPreparation.swift`, `SampleClock.swift`, `PCMSpool.swift`: Float32 mono spool, AVAudioConverter, integer half-up intended count, explicit at-most-one-frame tail correction or strict refusal, spool hashes | Sample-exact accounting does not imply universal acoustic alignment or identical SRC bytes across SDKs |
| Replay | `Sources/Replay/ReplayScheduler.swift:56`, `FrameIterator.swift`, `VirtualClock.swift`: realtime/accelerated absolute end-sample deadlines; rational speed; step acknowledgment barrier and separate virtual clock | Step is deterministic execution, not live latency; accelerated mode exists but the real-model campaign used 1x |
| Queue | `BoundedQueue.swift`: actor FIFO; capacity; blocking or drop-newest; cancellation/fail/close resumes; in-actor admission/dequeue timestamps | No drop-oldest; overall trace/history memory is not bounded merely because queues are bounded |
| Pipeline | `Sources/Experiment/ExperimentRunner.swift`, `Pipeline.swift`: one item/stream per process; ASR then diarization consume; prepare/replay/flush/shutdown/score/seal; explicit partial failure handling | Real campaign selected one active role and one passive counterpart, not simultaneous model operation |
| Persistence | `EventRecorder.swift`, `ArtifactIO.swift`, `RunPlan.swift`, `EnvironmentCapture.swift`: strict inputs, copied references, frozen settings, event prefix and artifact digests, final-only predictions, terminal status | Frozen runs contain absolute resolved paths; hash-valid files do not establish scientific truth |
| Real adapters | `RealAdapterSupport/StreamingWrappers.swift:106,194`, `ModelProfile.swift`, all four concrete adapter files | Optional build graphs and verified external assets; no complete combined product, standalone VAD benchmark, service/IPC API, or production voice engine verified |
| Diarization | Models consume streaming state; full timeline emitted only at flush; tolerance/quantization/union rules enforced | No online speaker-label latency |
| ASR | Cumulative or segment-indexed partial assembly; one untimed recording final; bounded callback mailbox for FluidAudio | No word timestamps; A2 upstream edge cases documented; some lost native information cannot be recovered from wrapper traces |
| Python | `analysis/src/phase0_analysis/{schemas,validate,score,asr_metrics,diarization_metrics,normalization,timing,resources,compatibility,compare,export}.py` | Analysis/scoring, not Python model inference; Python 3.12 only per pyproject/doctor |
| Scoring | NFC/casefold/punctuation-space normalization; WER tokens/CER code points; DER/JER zero collar, overlap retained, explicit UEM, speaker mapping; zero denominators not computable | Campaign references are custom recording-text and lexical word-union projections, not standard AMI scores |
| Telemetry | `Sources/Telemetry/ProcessSampler.swift`, `CTelemetry/TelemetryShim.c`, Python `resources.py`: runner CPU, current RSS/footprint and sampled reductions | No GPU/ANE/power observation; prepare is not isolated cold start; sampled process memory is not model-only or total unified memory |
| CLI | `Sources/BenchmarkCLI/*`, `Sources/Experiment/AnalysisCommands.swift` | Run/validate/compare/export exist. Swift `validate --run` writes a new `derived/` report and executes the run's frozen interpreter path; it is not a read-only portable artifact viewer |

Package floors: tools **6.2**; default/mock graph macOS 13, FluidAudio macOS 14, speech/both macOS 15 (`Package.swift:1,19,78`). Only macOS 26.6.2/arm64 was exercised here. The CLT Testing framework emits a macOS-14 linking-floor warning. Do not turn deployment declarations into a tested compatibility matrix.

## 5. Executed verification and limits

Tests used a temporary local clone of HEAD overlaid with the current tracked and nonignored untracked files. The existing `.venv` was symlinked into that snapshot; no existing evidence, vendor directory, or build directory was reused for the default Swift build. This isolates SwiftPM lock rewriting and test artifacts from the source checkout. It is **not** a cold Python install or a public-main clone test.

Host: arm64, macOS 26.6.2 (25G83), Swift 6.3.2, target arm64-apple-macosx26.0. Ambient `python3` is **3.14.7**, while `.venv/bin/python` is **3.12.14**. Environment for analysis: `PYTHONPATH=analysis/src`, `MPLBACKEND=Agg`, `PYTHONDONTWRITEBYTECODE=1`; Swift default graph explicitly `PHASE1_FRAMEWORKS=none`.

| Executed check | Result |
|---|---|
| `.venv/bin/python --version`; `.venv/bin/python -m pip check` | 3.12.14; no broken requirements |
| `swift build --disable-keychain` | Pass, new snapshot debug build |
| `bash scripts/swift_test.sh --disable-keychain` | **Fail:** 211 tests, 42 suites, one cancellation timing issue |
| Same suite with `--skip-build --no-parallel` | **Pass:** 211 tests in 42 suites |
| `--skip-build --filter cancellationStopsRealtimeReplayPromptly`, three separate invocations | All three pass; does not erase concurrent-suite failure |
| `.venv/bin/python -m pytest analysis/tests -q` | **266 passed** in 76.80 s, including untracked follow-up Python tests |
| `python -m phase0_analysis doctor --schemas schemas/v1 --project-root . --out <temporary>/doctor.json` using the venv | Pass |
| `python -m phase0_analysis schema-check --schemas schemas/v1 --fixtures testdata/schemas --out <temporary>/schema-check.json` using the venv | 133 documents; zero unexpected results; all targets have valid examples |
| `swift build --disable-keychain -c release` | Pass |
| `.venv/bin/python scripts/generate_fixtures.py --small --out datasets/fixtures --verify` | 55 regenerated files, zero mismatches |
| `.venv/bin/python scripts/e2e.py --voicebench .build/release/voicebench --out <new-temporary>/e2e` | **45/45 pass**, including intended negative exit codes |
| Direct release `run`, `validate`, `export`, second `run`, `compare` sequence in plan §4 | All exit 0; mock run completed, sealed validation pass, CSV/PNG outputs, compatible comparison |
| Saved real campaign: stream-hash all status-listed artifacts; recalculate accuracy through `score.accuracy` | 12 completed real-labelled runs, 132 matching seals; all consumed 16,638,080 samples, zero drops; no accuracy-record differences; content identical within each row |
| Pattern scan of current tracked/nonignored untracked text and all reachable-history blobs | No matches to the tested credential patterns in 441 reachable blobs; limits below |
| Explicit local Markdown file-link target check | No missing file targets found; inline-code references are not covered by this result |

The concurrent cancellation check measured **391,712,542 ns** against the **200,000,000 ns** bound at `Tests/ReplayTests/ReplayModeTests.swift:174–185`. Isolated passes plus the serialized suite suggest load/scheduling sensitivity; the root cause is **unverified**, not a demonstrated production cancellation defect. Preserve the failure log and separate deterministic cancellation correctness from wall-clock characterization before advertising a stable test gate.

Mock output observed: WER 0.400000, CER 0.153846, DER 0.250000, JER 0.416667. These are deliberately scripted errors on tones/silence, not model-quality results. Status, mock labelling, sample coverage and artifact existence are the primary smoke assertions; do not freeze machine-dependent timing/memory values.

Full local verification records are retained at:

```text
/var/folders/70/wqwvj4qd1hlg3p_yl4xlmwlh0000gn/T/voicebench-publication-audit-tuioxsam/
  baseline.json, checks.json, extra-checks.json, readme-commands.json
  cancellation-retries.json, campaign-evidence-check.json
  build.log, swift-tests.log, swift-tests-serial.log, pytest.log
  doctor.json, schema-check.json, fixtures.log, e2e/commands.json
```

Temporary logs are local diagnostics, not committed or durable public evidence. Material results are recorded above so these documents do not depend on their retention. Command families also executed: `git status --short --branch`, `git branch -vv`, `git log --all`, `git ls-files`, `git ls-tree -r main`, `git submodule status`, `git count-objects -vH`, `git diff`, `rg`/full or targeted source reads, metadata inspection, SHA-256 inventory, and read-only GitHub/API requests. No model campaign or asset acquisition was run.

## 6. Findings and implementation mapping

Effort: S = localized edit; M = several coordinated files/checks; L = cross-environment or owner-dependent work. Risk describes the proposed fix.

| ID | Priority | Finding / evidence | Visitor impact | Recommended fix / plan task | Effort / risk |
|---|---|---|---|---|---|
| F01 | P0 | Public `main` tree contains only README; remote/local main `4a5d3ab…`; implementation is on local `imp/phase-1`, with unpublished working changes | Clone has no package, tests, data or commands | Preserve work; assemble reviewable publication branch from verified implementation; integrate only after approval: T00, T01, T60 | M / integration omission |
| F02 | P0 | `README.md:3` and live GitHub description claim a complete combined ASR/diarization/VAD engine; current README status says mock-only despite Phase 1 | Fundamentally misleading landing page | State benchmark-harness scope, optional real adapters, separate active-role campaign, planned engine; owner applies matching metadata: T10, T30, T61 | S / low |
| F03 | P0 | No LICENSE; GitHub license null; `docs/dependencies.md:5,10–15` covers old Phase 0 only; synthetic manifest license unresolved; model notices external | Publicly visible code is not an explicitly licensed open-source release; redistribution boundaries unclear | Owner chooses code/fixture rights; complete third-party/model/data notices; retain external assets; no invented compatibility clearance: T11 | M / owner-dependent |
| F04 | P1 | README runs before setup, uses Homebrew absolute Python path, compares nonexistent `runs/a`/`runs/b`, lacks success/output explanation; `pyproject.toml` requires 3.12 while ambient Python is 3.14 | Newcomer must reconstruct prerequisites and cannot follow the whole example as written | One doctor/setup/smoke route using existing fixtures, tested command block and output expectations: T20, T21, T30 | M / environment handling |
| F05 | P1 | Phase 1 guide has ellipses/placeholders, unbound `$INPUTS`/`$SESSION`, manual external assets, no complete checked-in acquisition/recreation recipe; path dependency is not lock-pinned | Real-model reproduction requires author help | Concrete no-secret input template with all fields, pinned model/file/patch provenance, bounded acquisition instructions and smoke-only route: T22 | M–L / network/rights |
| F06 | P1 | All raw evidence/CSVs/figures ignored; results cite local-only paths; `dataset-freeze.json` records failed RMS check and no listening check; saved configs freeze absolute interpreter/root paths | Visitor cannot trace headline numbers or reuse copied runs through Swift CLI | Curated small evidence index and rights-approved summaries; read-only Python validation guidance; execution/scientific validity split; keep accuracy conditional or omit it from headlines: T12, T31 | M / accidental alteration/disclosure |
| F07 | P1 | Changed manifest depends on untracked native tests; corrected results depend on untracked review/history/follow-up scripts | A partial commit could be broken or lose corrections | Review and explicitly stage coherent owner work; preserve historical records; never bulk-stage ignored assets: T00, T01 | M / owner work loss |
| F08 | P1 | Concurrent Swift baseline failed cancellation timing; 3 isolated retries and all-serial 211-test suite pass | Unstable advertised test gate/CI | Diagnose, preserve correctness checks, isolate timing characterization with bounded completion tests; no blind threshold increase: T50 | M / hiding a real race |
| F09 | P1 | No `.github` workflow in tracked tree; public API has zero workflows/runs | No independently visible build/test signal | Portable Python subset plus macOS mock build/test/smoke; optional separately reported native model-free SDK job; honest status: T51 | M / runner compatibility |
| F10 | P1 | `docs/contracts.md:1,72` describes M2/future M3; `docs/api-verification.md:11` says tools 6.0 versus actual 6.2; root Phase 0 report still reads as broad readiness; root map omits real modules | Current behavior and historical milestones blur; useful architecture is hard to find | Current doc index/architecture/methodology/development pages; label historical records; preserve useful contracts and decisions: T30–T33 | M / stale cross-references |
| F11 | P1 | Default build rewrites committed both-graph lock: source SHA `aee60879…` → snapshot none-graph SHA `618f25a5…`; guide acknowledges graph switching | Normal onboarding dirties tracked state; dependency inventory no longer matches lock | Make default root lock match default graph; preserve exact historical both lock with campaign provenance; document isolated optional builds: T23 | M / transitive drift |
| F12 | P2 | `scripts/e2e.py:32–33`, `determinism.py:40–41`, `characterize.py:145–146`, `offline_smoke.sh:20` recursively remove supplied output; `.gitignore` omits README `exports/`, `comparisons/`, local `diff.txt`; unanchored `evidence/` also hides the proposed curated packet | Rerun may destroy evidence or stage output debris | Refuse existing user output; test sentinel preservation; add narrowly scoped ignores and anchor private root evidence rule; leave existing files intact: T40 | S–M / legacy automation expectations |
| F13 | P2 | `vendor/speech-swift/PHASE1_VENDOR.json` names obsolete one-file patch; actual patch/diff changes two files; report `eligibility()` trusts ledger validation and counts entries | Rebuild provenance and future generated status can mislead | Refresh new vendor records without editing history; verify actual patch identity; optional small report distinct-repetition/seal checks: T41, T52 | M / changing report eligibility |
| F14 | P2 | No contributor/security guide, empty topics/homepage, no public verification badge or reviewed release workflow; protection details inaccessible | Harder navigation and contribution; release process unspecified | Proportionate CONTRIBUTING/SECURITY, PR checklist; owner metadata/protection review; no badge before successful workflow: T33, T61 | S / external approval |

F08, F11 and F12 were directly demonstrated or source-inspected in this audit. F13 agrees with the independent review, but is also grounded in the current vendor record/diff and report source. No current saved campaign corruption was found.

## 7. Visitor journey and reproducibility gaps

| Stage | Current friction | Required publication behavior |
|---|---|---|
| GitHub arrival | Public README/description promises engine; implementation absent on main | Brief, accurate harness description on the integrated default branch |
| Choose a path | Phase 0 history dominates; no real/mock decision at top | First try synthetic mock; optional real-model guide clearly separated |
| Install | Python location assumed; no preflight; first commands precede setup | Check arm64/macOS/toolchain/Python 3.12; show network setup and supported baseline |
| First run | Data actually exists but purpose/success unclear | Use committed 12-second tone fixture; no models, datasets or account needed |
| Inspect artifacts | Output list/immutability/reuse rules scattered | Explain `status.json`, `events.jsonl`, `predictions.json`, `metrics.json`, `validation.json`, telemetry and derived reports |
| Real benchmark | External owner-specific config, model assets, vendor patch, sandbox requirements | Full pinned-input template/recipe; missing prerequisites fail clearly; fresh output directory; optional smoke before measured work |
| Read results | Narrative exists locally; raw packet excluded; validation conditional | Small curated summaries/provenance plus limitations near figures; durable evidence choice |
| Read architecture | Module map and historical implementation details, no current overview | One accurate pipeline diagram, boundaries and links to maintained deep documents |
| Contribute | No CI or concise workflow | Portable/native check matrix, scope, review process, licensing and data policy |

The already verified mock sequence is in plan §4. There is no need to generate a new speech recording, introduce a downloader, add a web interface, or replace Swift/Python layouts to close the initial onboarding gap.

### Campaign provenance and claims

Historical campaign root: `evidence/phase1/one-shot/20261021-s2/`. Matrix: four rows × three fresh processes, 1x realtime, 16 kHz mono, 20 ms/320-sample frames, capacity 32/block, AMI ES2008a crop 1,039.88 s. One active role per run. Full recorded binary SHA:

```text
5f8ccfe372b246d2e64b75b23b87706ae94c7c1c71adf2ebbe3c0247261931c8
```

Framework pins: FluidAudio `61d41b3ca04833d1cb80632c82ba401f117a01ef`; speech-swift `3f58a58a8f867a4c87b97dbf4d6050d6a88ef665` plus `patches/speech-swift-3f58a58a-phase1.patch`. The local vendor record is stale; the path dependency must be authenticated separately from `Package.resolved`.

Reproduced scores: A1 WER 0.233035/CER 0.164800; A2 0.237882/0.172530; D1 DER 0.245611/JER 0.243300; D2 0.203778/0.198934. They are fractions under the custom policies, not universal comparisons. These checks reuse the project scorer implementation; the prior independent review records separately implemented arithmetic checks. Do not describe this audit's scorer reuse as a new independent scoring implementation.

Frozen acoustic check ratios are 1.20305 / 1.83062 / 1.28638 against threshold 1.5; status `fail`, `listening_check_performed: false`. This is an uncalibrated check, not proof of bad alignment or proof of good alignment. A manual check is outstanding. Choose a methodology-focused publication with explicit conditional scores, or wait for that check before validated-accuracy claims. No mandatory performance rerun is warranted for a narrowly scoped harness release.

The corrected results withdraw the 11–13x claim. Adapter service RTF is summed consume/flush wall duration divided by audio duration; its reciprocal is not measured saturated throughput. Final-only diarization does not expose online label latency; ASR emits no word times. Model conversion, precision, postprocessing, decoder behavior and reference projections confound framework attribution. A2 frame skipping after EOU remains unauditable from saved traces. Preserve all these boundaries.

## 8. Security, privacy, and licensing assessment

No credential-pattern matches were found in current tracked/nonignored untracked text or 441 reachable-history blobs using patterns for private keys, GitHub tokens, AWS access keys, Hugging Face tokens, OpenAI-style keys, and long quoted credential assignments. No tracked `.env`, private-key, model-weight, real AMI audio or archive paths were found. The tracked WAVs were traced to `scripts/generate_fixtures.py` and hash verification passed. This is a bounded pattern audit, not a secret-free or vulnerability-free certification. It did not inspect unreachable objects, remote-only refs, all ignored logs, encoded secrets, package advisories, or every third-party implementation.

Personal absolute paths are few in tracked files: Homebrew setup assumptions in README; an optional Xcode example in the Phase 1 guide; deliberately illustrative absolute paths in `testdata/schemas/valid/config/frozen-example.json`. Do not rewrite intentional parser fixtures as if they were accidental user data. Ignored campaign artifacts have many real resolved paths, dataset transcripts, hardware facts and authorization notes; export only an explicitly reviewed subset. `diff.txt` was included in the nonignored pattern scan, but is not recommended for publication.

`Sources/Experiment/AnalysisCommands.swift:22–33` trusts the interpreter/project-root from run config. Document that Swift analysis commands apply to trusted locally generated runs. For portable downloaded evidence, use the current checkout's trusted Python analysis directly after inspection; do not promise a sandbox for untrusted run directories. Changing artifact path semantics is optional future engineering, not a prerequisite rewrite.

Rights facts, **not legal clearance**:

- Project license is explicitly unselected in `docs/dependencies.md` and fixture metadata. Owner must choose terms and scope; public visibility alone does not resolve the intended reuse terms.
- Existing dependency inventory covers argument-parser/Yams and the Python environment, but not the 41-pin optional graph and speech-swift path source. Preserve exact upstream license/notice texts and the separately embedded libyaml notice before binary redistribution.
- The official [AMI corpus license page](https://groups.inf.ed.ac.uk/ami/corpus/license.shtml) identifies corpus/annotation terms as CC BY 4.0. This supports a provenance/attribution plan, not blanket permission to publish every artifact without review.
- The [Fluid Sortformer conversion card](https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml/blob/main/README.md) declares CC BY 4.0; the [speech Parakeet INT8 card](https://huggingface.co/aufklarer/Parakeet-EOU-120M-CoreML-INT8/blob/main/README.md) declares NVIDIA Open Model License. Local saved model notices and owner input records distinguish original-checkpoint and conversion terms. Never apply one repository code license to all models/data.
- Current web cards are not substitutes for revision-specific notices. Local input records pin the four conversions to `ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1`, `47707a55d23633d3947f168a46ad46960a8639b9`, `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`, and `fca97346c39ef8cc046e7b13515972f6db48e2ee`, respectively D1/D2/A1/A2. They record acceptance for local use; that is not an approval to redistribute asset trees or publish owner notes.

No dependency incompatibility has been established; a complete compatibility review is pending. Do not fabricate a LICENSE, redistribute weights/AMI recordings, rotate nonexistent credentials, or rewrite history on the basis of this audit.

## 9. Documentation disposition

Keep package names and directories. Preserve `docs/decisions.md`, `implementation-log.md`, API ledger, contracts, CLI reference, adapter guide, Phase 0 readiness report and M2 hardening report as useful evidence. Add a current index and historical labels; correct claims in maintained reference pages without rewriting historical measurements. Preserve `docs/phase1/history/*` as clearly superseded records, and link to the corrected current report. The duplicated narrative source in `docs/readiness-narrative.md` is an input to the report generator, not automatically redundant debris.

Markdown target checks passed for explicit links, but many important references are inline code to git-ignored paths or missing historical planning packs. Replace visitor-critical references with maintained local documentation or an evidence index. Do not copy private source plans into the repository merely to repair those references.

Proposed current documents and ownership are detailed in plan §2–3. A new architecture overview should link to contracts and methodology rather than repeat every schema field. README should remain an entrypoint, not the complete implementation log.

## 10. Not verified and owner decisions

Not rerun/verified here:

1. Cold Python dependency installation from the hash lock, clean anonymous public clone onboarding, or a fresh machine with empty caches. Existing venv and user SwiftPM caches were available.
2. Optional FluidAudio/speech/both rebuilds, native SDK stub tests, real-model inference, long P01–P04 characterization, Thread Sanitizer, or the enforced-offline full smoke. Historical records/source were inspected; default/mock checks are not native-inference proof.
3. Manual AMI listening/alignment, new ES2008b work, saturated throughput, accelerator placement, power, thermal/fan behavior, causal framework superiority, or broader hardware/OS support.
4. Full license compatibility/advisory review, branch protection/ruleset details, GitHub rendered Mermaid, anonymous browser access, or the accompanying LinkedIn caption (none was supplied).

Owner decisions to carry forward, without blocking completion of this planning pass:

| Decision | Default planning position |
|---|---|
| Code and project fixture/document license | Pending explicit license choice; no auto-selection |
| Which aggregate/derived results may be published, and where larger evidence is hosted | Prefer small redacted summaries/index; no audio, weights, transcript text or authorization notes by default |
| Accuracy publication scope | Harness/methodology release may retain clearly conditional evidence; validated-accuracy headlines wait for human check |
| Public name/description/topics | Keep current repository URL/name; propose accurate description; settings changes require approval |
| Treatment of `diff.txt` and historical/private planning material | Preserve; do not delete or import wholesale |
| Push, PR creation, merge, visibility, protection, tags/releases | Prepare local reviewable changes first; external publication/integration requires explicit authorization |
| Additional experiments/downloads/asset redistribution | Not part of initial publication work; separate authorization and rights review |

The host already supports the verified default path. A Makefile or small shell entrypoint is a routine implementation proposal, not a licensing/publication decision; use one only if it reduces the documented steps. Any genuinely destructive cleanup or history rewrite requires separate owner approval and is unnecessary for this plan.
