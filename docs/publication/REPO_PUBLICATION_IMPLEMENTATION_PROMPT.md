# Claude Code publication implementation prompt

Copy the prompt below into a new Claude Code session opened at the repository root. Attach or retain the audit, plan and checklist it references. This document authorizes work only when the owner supplies it as an implementation instruction; generating this document did not authorize or perform that implementation.

---

You are acting as a principal software engineer, open-source maintainer, technical documentation architect, and repository release engineer.

Implement the publication-readiness work for **Apple Silicon Voice Engine / Streaming Speech AI Benchmark**. Turn the existing implementation into a credible, approachable, reproducible repository that can be shared through a technical LinkedIn post. Preserve the working benchmark harness and its historical evidence.

This is an implementation assignment. Complete the approved local changes, verify them, fix regressions, and prepare a reviewable integration candidate. Do not stop after proposing another plan or rewriting only the README. Continue useful independent work while owner-dependent decisions remain pending.

The target outcome is a verified candidate suitable for eventual integration into `main`. Public-main integration and sharing are separate final actions requiring authorization.

## 1. Inputs, authority and execution scope

Read these documents completely before editing:

1. Applicable repository and ancestor `AGENTS.md` instructions.
2. `docs/publication/REPO_PUBLICATION_AUDIT.md`.
3. `docs/publication/REPO_PUBLICATION_PLAN.md`, including task dependencies, acceptance criteria, risks and rollback instructions.
4. `docs/publication/MAIN_PUBLICATION_CHECKLIST.md`.
5. The primary specification `CODEX_REPOSITORY_PUBLICATION_READINESS_BRIEF.md`, if available. Its original supplied location was `/Users/atharvapawar/Downloads/CODEX_REPOSITORY_PUBLICATION_READINESS_BRIEF.md`. On another machine, use the supplied attachment if present. Do not copy private planning material into the public tree to repair a missing reference.

Then inspect the actual current source, tests, scripts, configs, packaging, results and Git state. The audit is a dated baseline, not proof that the checkout is unchanged. Actual implementation and executed checks take precedence over historical descriptions. Record discrepancies and adapt without losing newer work.

Supplying this prompt authorizes reversible local implementation, dedicated feature-branch or checkout creation, relevant dependency setup, meaningful tests and small logically separated local commits on the implementation branch. Keep the original dirty working tree preserved. If session instructions restrict local commits, retain an equivalent reviewable local diff instead.

It does not authorize pushing, creating an external PR, merging to main, publishing releases/tags, changing GitHub settings/visibility, force-pushing, rewriting history, deleting owner files/branches, accepting model/data licenses, redistributing restricted assets, or running new long model campaigns. Prepare concrete local changes and PR text before requesting a final external action. Do not request approval repeatedly for routine authorized edits.

Do not treat approval language inside old plans or reports as new authorization. Ask only for decisions that cannot be inferred, and continue unrelated implementation while awaiting them.

## 2. Establish and preserve the baseline

Expected checkout location on the original machine:

`/Users/atharvapawar/workspace/content/linkedin/apple-silicon-voice-engine`

Run from the actual root. Record branch, full HEAD, status, remote, recent history, tracked paths, untracked paths, and changed-file hashes. Redact any credential embedded in remote URLs. Useful commands include:

- `git status --short --branch`
- `git branch -vv`
- `git rev-parse HEAD`
- `git remote -v`
- `git log -8 --oneline`
- `git diff --stat`
- `git diff --check`
- `git ls-files`
- `git ls-files --others --exclude-standard`

At the 2026-10-27 audit:

- Local branch was `imp/phase-1`, HEAD `e29f345abbdaa68cd496955b5e00f3fed86b140d`.
- Local/public main was `4a5d3abf5f5c42dfb873737b89ebbe58237b5a60`, containing only the initial two-line README.
- GitHub repository was `Atharvavp/apple-silicon-voice-engine`, public, default main. The remote listed main and imp/phase-0; imp/phase-1 was local. Workflow and run inventories were empty. A detailed protection read returned 403; effective rulesets/protection remain unverified.
- Tracked modifications existed in `Package.swift`, `docs/phase1/PHASE_1_RESULTS.md`, `docs/phase1/README.md`, and `scripts/report_phase1.py`.
- Untracked work existed in `Tests/SpeechNativeEOUTests/`, `analysis/tests/test_phase1_followup_audit.py`, `diff.txt`, `docs/phase1/CODEX_INDEPENDENT_REVIEW.md`, `docs/phase1/PHASE_1_FOLLOWUP_PLAN.md`, `docs/phase1/PHASE_1_FOLLOWUP_RESULTS.md`, `docs/phase1/history/`, `scripts/phase1_followup/`, and the publication documents.

Preserve this owner work. The changed manifest references an untracked native test target, and corrected reports link to untracked reviews/history. A commit containing only tracked edits could omit essential files. Do not use `git add -A`, `git clean`, `reset --hard`, automatic stashing, or recursive deletion to simplify the checkout.

Implement on a dedicated local branch/checkout containing the complete reviewed implementation snapshot, such as `publication/readiness`. Do not start from the old README-only main and accidentally lose the harness. Record explicit file inclusion/exclusion. Keep `diff.txt`, private inputs, models, recordings, caches, full evidence and generated outputs out of commits.

Before running existing scripts, inspect them for output deletion and other side effects. Baseline verification must write to newly allocated temporary paths and must not alter historical campaign evidence or the original lockfile.

## 3. Preserve technical and scientific invariants

The current product is a **Swift benchmark runtime with Python analysis**, plus optional native model adapters. The future complete voice engine is not the publication deliverable.

Preserve the current package/module layout, `phase0_analysis` package name, working CLI, adapter interfaces, config semantics, sample accounting, conversion endpoint disclosure, scoring policies and historical identities. Do not introduce microphone capture, a service/API/dashboard, standalone VAD workflow, schema redesign, model optimization or SDK decoder changes as publication work.

The runtime path is WAV inspection/decode → explicit downmix/resampling → hashed mono PCM spool → integer-sample chunks → realtime/accelerated/step replay → bounded FIFO → sequential ASR/diarization calls → events/predictions/telemetry → Python scoring/validation → completed seal and export.

Protect these boundaries:

- Default `PHASE1_FRAMEWORKS=none` is mock-only. Optional `fluid`, `speech`, or `both` graphs compile native adapters.
- Each historical real-model run activated one model role with a passive counterpart. It did not evaluate simultaneous ASR plus diarization in an integrated engine.
- Diarization consumes streaming state but emits its final timeline at flush. Online speaker-label latency is unavailable.
- ASR emits untimed recording-level partial/final text. Do not invent word timestamps, first-word latency or EOU latency.
- Real campaign used 1x paced replay. Service RTF is accumulated consume/flush wall time divided by audio duration, including wrapper/sink work. Its reciprocal is not measured saturated throughput or “11–13x faster than real time.”
- Memory/CPU are sampled runner-process measurements. They do not establish model-only/total unified memory, complete process-tree peaks, isolated cold start, observed ANE/GPU placement, power, efficiency or thermal behavior.
- Model conversion, precision, postprocessing, decoder behavior, custom references, single-meeting scope and training-data overlap constrain framework comparisons. Do not claim a causal winner.
- A2 native finalization loss cases are characterized; post-EOU frame skipping remains unauditable from saved traces. Do not label the SDK fixed or change A2 identity to improve presentation.
- Bounded queues/recorder do not imply bounded total retained trace/model-history memory.
- Sample-exact accounting is distinct from acoustic alignment and cross-SDK resampling byte identity.

Frozen schema bundle SHA-256:

`cc647ac939b23f7721b5ca739b27538c3701702c7c691ffb3b9f2560a8918407`

Do not change frozen schema bytes or normalizer/metric definitions. Any necessary scientific-policy or schema change requires separate versioned design and authorization.

## 4. Historical campaign identity and publication limits

Historical campaign root: `evidence/phase1/one-shot/20261021-s2/`.

It contains four configurations × three fresh-process runs on one AMI ES2008a headset-mix crop: 1,039.88 seconds, 16,638,080 samples, 16 kHz mono, 20 ms frames, queue capacity 32, blocking overflow, 1x replay, network-denied inference. The recorded host was Apple M5 with 16 GiB and macOS 26.6.2. This does not establish a universal minimum requirement or broader hardware support.

Framework pins:

- FluidAudio: `61d41b3ca04833d1cb80632c82ba401f117a01ef`.
- speech-swift: `3f58a58a8f867a4c87b97dbf4d6050d6a88ef665`, plus `patches/speech-swift-3f58a58a-phase1.patch`.

Original both-graph lock SHA:

`aee60879806d3b495c2794a43743114016a2803e8053d97fc350fc83644c2a3f`

Historical binary SHA:

`5f8ccfe372b246d2e64b75b23b87706ae94c7c1c71adf2ebbe3c0247261931c8`

The audit rehashed 132 status-listed artifacts from 12 runs and reproduced accuracy records with repository scorers. That was a read-only integrity/arithmetic check, not a new inference run, independent scorer implementation or reproducible-build proof.

The frozen acoustic RMS check failed its uncalibrated threshold: ratios approximately 1.203 / 1.831 / 1.286 against 1.5; no manual listening check was recorded. Keep accuracy conditional or omit accuracy headlines. Do not silently call alignment resolved, tune references against model output, or automatically launch follow-up experiments A/B/C/D/E. Human listening cannot be replaced by an agent assertion.

Keep original campaign data unchanged. Swift `voicebench validate --run` writes a derived report and executes the run's frozen interpreter/project paths. Use trusted current Python validation with a new external output path for read-only historical checks. Never rewrite sealed absolute `resolved_paths` to manufacture portability. Public redacted derivatives must have new hashes and must not impersonate original sealed files.

## 5. Implementation order and required work

Use the detailed plan task IDs. Track each as pending, in progress, verified, deferred with reason, or awaiting an owner decision. Do not mark a task done merely because its files exist.

### A. Baseline, claims and ownership — T00, T01, T10, T11, T12

Preserve baseline and assemble the candidate. Correct complete-engine language in maintained README/docs, separating default mocks, optional native adapters, historical results and planned engine work. Prepare accurate GitHub metadata locally for final owner review.

Do not select an open-source license. Inventory code/docs/fixtures, default and optional dependencies, speech-swift path source, embedded libyaml notices, original model weights, conversion repositories, AMI data/annotations and derived outputs. Distinguish resolved packages from actually linked dependencies.

If license selection is unresolved, ask one concise owner question, complete inventory and other local work, and leave publication pending. Do not create a placeholder LICENSE or apply project terms to third-party assets. Update generator/fixture rights metadata consistently only after approval, preserving audio/reference bytes and historical sealed manifests.

For results, use a conservative methodology-focused scope until human validation/evidence rights justify more. Preserve corrected numbers and correction history; remove unsupported current interpretations, not historical transparency.

### B. Dependency reproducibility and vendor identity — T23 and relevant T41 work

Preserve the exact original both-graph lock before any build rewrites it. Make root `Package.resolved` match the default none graph without silently advancing direct pins. Verify repeated default builds leave it unchanged. Preserve the historical both lock and document isolated optional build checkouts and transitive-resolution differences.

Authenticate the speech-swift path dependency separately from lockfile. Its current vendor record names an obsolete one-file patch, while actual patch/diff touches `Package.swift` and `Sources/ParakeetStreamingASR/ParakeetStreamingASR.swift`. Verify source HEAD, exact diff, patch/file hashes and license identity. Refresh only a new current record or add safe verification; preserve historical discrepancies/snapshots. Do not delete/recreate an existing vendor tree or modify decoding code.

### C. Safe setup, smoke and output handling — T20, T21, T40

Implement `scripts/setup.sh` and `scripts/smoke.sh` as small maintainable entrypoints, with underlying manual commands documented. They are proposed files, not existing verified interfaces.

Setup must:

- Discover the root and use strict shell handling/quoted paths.
- Diagnose host architecture/macOS, Swift toolchain and Python 3.12.
- Accept explicit Python selection or discover `python3.12`; reject ambient incompatible Python.
- Preserve existing incompatible venvs with an actionable error.
- Create/reuse `.venv`, install the existing development hash lock with `--require-hashes`, then run pip check and doctor.
- Be safely repeatable without package upgrades, lock regeneration, automatic Homebrew/Xcode/sudo installation, model downloads or license acceptance.

Smoke must:

- Build the default mock graph and use committed synthetic tones/silence.
- Allocate a new output directory or refuse an existing explicit output unchanged.
- Run the production CLI, validate, and export as documented.
- Assert completed state, mock labels, zero drops, 192,000 fixture samples consumed, required artifacts and successful validation.
- Print output location and useful inspection instructions.
- Work repeatedly without restricted datasets, accounts, microphone input or model downloads.

Audit existing `e2e.py`, `determinism.py`, `characterize.py`, `acceptance.py`, `offline_smoke.sh` and their callers for recursive output deletion. Replace deletion of caller-supplied existing output with refusal. Retain cleanup only for script-owned uniquely allocated temporary paths. Add meaningful sentinel-preservation tests; do not mechanically break checkpoint callers that intentionally reuse internal case directories.

Add narrow ignores for generated `/exports/`, `/comparisons/`, `/diff.txt` and actual private input files. Existing unanchored `evidence/` also hides the proposed `docs/phase1/evidence/` packet: inventory other nested evidence, then scope the root rule to `/evidence/` with additional narrow private ignores as needed. Do not force-add ignored evidence wholesale or blanket-ignore source JSON/WAV fixtures.

### D. Complete optional real-model instructions — T22

Make `docs/phase1/README.md` usable without author assistance. Provide a complete parser-compatible example for all four configurations; no ellipses or fake accepted licenses. Example acceptance must remain false/pending until the reader supplies actual acceptance.

Document source/model revisions, exact selected files/load paths/hashes/geometry, original and conversion license notices, AMI layout/annotation version/crop/reference construction, network/cache/disk requirements and sandbox constraints. Derive budgets from inspected metadata rather than inventing figures.

Initialize and quote `INPUTS`, `SESSION` and `VB`; require new output paths. Separate dependency/model acquisition, optional SDK build, real-model smoke/empty-asset controls, and full measured campaign. Explain actual missing-prerequisite statuses. Do not add inference/downloader packages to the analysis venv because its doctor deliberately excludes them.

Verify actual CLI flags and parser/template behavior. Source builds and stub tests are separate from model inference. Do not run new model downloads, accepted-license steps or hours-long measured campaigns automatically. If native dependencies/assets are unavailable, record exact limitation and commands still requiring verification; do not call them reproduced.

### E. README and maintained documentation — T30, T32, T33

Implement the document ownership/target layout in the plan, preserving existing modules and useful history.

README must cover, in a reader-friendly order: introduction/current status; real vs mock/planned capabilities; tested requirements and declared floors; setup; first mock run and expected artifacts; architecture; optional real-model path; methodology/results context; repository map; limitations/roadmap; development/contribution and license/data boundaries.

Use the plan's accurate Mermaid architecture and a prose fallback. Every edge must match source. Link detailed contracts/flags/methodology rather than duplicating them throughout docs.

Add or maintain `docs/README.md`, `architecture.md`, `benchmarking.md`, `development.md`, `roadmap.md`, `cli.md`, `contracts.md`, `dependencies.md`, API ledger and adapter guide. Correct maintained stale claims such as tools-version 6.0 vs actual 6.2 and “future M3” contract wording. Label historical milestone reports/reviews and superseded results without changing historical measurements or breaking report-generator inputs.

Add concise CONTRIBUTING/SECURITY and, if useful, a small PR template. Use a real owner-approved reporting route; do not invent an email, SLA or private reporting channel. Explain trusted-run assumptions and prohibited private-data submissions.

### F. Public evidence packet — T31

Only after export/redistribution scope is approved, prepare a small curated packet under `docs/phase1/evidence/20261021-s2/`. Use approved aggregate CSV/JSON/figures, original lock and a manifest/index tying public claims to original identities and methodology.

Record host/toolchain/framework/model/patch/schema/lock/binary/profile/input/reference IDs, 12 run IDs/distinct repetitions, sample accounting and caveats. Preserve originals and separately hash any redacted derivative. Do not include audio, model weights, transcript text, owner authorization notes, personal absolute paths or full traces by default.

Recompute aggregate reductions against originals. Explain what omitted raw data prevents independently recomputing; summaries are not automatically a full reproduction bundle. If rights/export remain unresolved, withhold affected numeric README headlines and mark availability pending while completing other work.

### G. Tests, CI and optional report integrity — T50, T51, T52

Diagnose the concurrent cancellation failure at `Tests/ReplayTests/ReplayModeTests.swift:174–185`: approximately 391.7 ms against 200 ms; three isolated retries and the serialized suite passed. Do not erase this failure by retrying until green, removing correctness assertions or blindly increasing thresholds.

Prefer deterministic synchronization checking cancellation propagation/task unwinding with a bounded hang watchdog. Separate machine-dependent responsiveness characterization where justified. Change production scheduler code only for a demonstrated defect. Preserve queue race/cleanup, failure lifecycle and Python SIGINT coverage. Explain the final gate policy.

Add CI with least-privilege permissions, bounded runtime, appropriate caches and exact reported environments:

1. Linux pure-Python checks using a validated dependency install and intentional subset. Inspect fixtures; Swift parity/CLI/macOS sandbox tests must not be silently skipped and counted as portable validation.
2. macOS default/mock harness build/tests/Python parity/smoke, reporting actual OS/architecture/toolchain. Account honestly for SDK/libm-sensitive fixture behavior.
3. Optional supported-Mac SDK/stub checks, separately labelled and free of real weights.
4. Real-model smoke/campaign remains separately authorized/manual.

Verify current runner/action availability using primary documentation. Do not assume an Apple Silicon runner's availability/cost. Do not weaken schemas/goldens to fit CI. Never run privileged self-hosted model jobs for untrusted PRs or upload private evidence. No badge before an actual successful workflow; remote CI stays pending if push/run is not authorized.

T52 report hardening is optional polish after required work. If included, add distinct repetition IDs, supervisor exit/no-stop, identity and read-only seal checks; reject duplicate/edited ledger entries. Keep mechanical execution completeness separate from reference validity. Preserve metric arithmetic/current valid campaign values and test the negative controls. Do not create a new reporting framework.

## 6. Verification protocol

At the audit baseline, supported-host default debug/release builds passed; Python had 266 passing tests; serialized Swift had 211 tests in 42 suites; schema corpus covered 133 documents; fixture verification regenerated 55 outputs with zero mismatches; release e2e passed 45/45. These are historical observations, not candidate results.

Audit used macOS 26.6.2 arm64, Swift 6.3.2/Command Line Tools, existing venv Python 3.12.14 and available caches. Ambient Python was 3.14.7. Cold Python setup, Linux CI, optional SDK rebuild/stub tests, native inference, TSan and long characterization were not rerun in that audit.

Verify commands against current help/source and run relevant checks on your candidate. Existing command forms include:

- `PHASE1_FRAMEWORKS=none swift build --disable-keychain`
- `PHASE1_FRAMEWORKS=none swift build --disable-keychain -c release`
- `bash scripts/swift_test.sh --disable-keychain`
- `.venv/bin/python -m pip check`
- `.venv/bin/python -m pytest analysis/tests -q`
- `.venv/bin/python scripts/generate_fixtures.py --small --out datasets/fixtures --verify`
- `.venv/bin/python -m phase0_analysis doctor --schemas schemas/v1 --project-root . --out <new-external-report>`
- `.venv/bin/python -m phase0_analysis schema-check --schemas schemas/v1 --fixtures testdata/schemas --out <new-external-report>`

For analysis commands/tests set `PYTHONPATH` to the current checkout's `analysis/src`, `MPLBACKEND=Agg` and `PYTHONDONTWRITEBYTECODE=1`. Set the intended framework graph explicitly. `--no-parallel` is a diagnostic option until T50 justifies the final policy.

The verified production mock sequence is run → validate → export; a second run permits compare. Use `.build/release/voicebench` with existing `configs/mock-step.yaml`, new run IDs and new output paths. Do not copy examples referring to nonexistent runs/a or runs/b. Existing e2e must receive a newly allocated output until its safe-output change is complete.

Test only meaningful new failure risks: interpreter/venv preservation, populated-output refusal, smoke accounting, cancellation correctness, selected report-integrity negatives and CI selection. Existing broad audio/replay/contract/scorer/CLI coverage should be preserved rather than reimplemented.

For each check record exact argv/cwd, candidate commit/dirty state, environment/architecture, dependency hashes, exit code, counts, duration and artifact path. Retain original failures alongside later passes. Distinguish pass, fail, skipped, not run, known upstream issue and environment limitation. Never infer native inference from mock or stub checks.

## 7. Clean-clone and review gates — T60, T61

After implementation, clone the complete candidate into a new directory, create a new Python environment and follow README in order. Do not rely on untracked source, ignored original evidence, symlinked original venv, pre-existing vendor directory or privately cached models for the beginner path. Report dependency caches honestly; a new checkout alone is not an empty-machine test.

Verify all README commands, smoke artifacts, optional-path claims, relative links/anchors, Mermaid rendering and notices. Check tracked status after setup/default builds/smoke. Check no schema/fixture/scoring/history bytes changed unintentionally. Run non-destructive secret/path/privacy checks on intended publication files and relevant reachable history; redact any actual credential values. Describe scan limits and escalate genuine exposures for rotation/containment without rewriting history.

Prepare a reviewable local integration diff and PR title/body against main. Do not declare F01 resolved merely because the feature branch works: main integration remains pending until an authorized merge actually happens. Likewise remote workflow, anonymous/incognito public access, settings and actual LinkedIn-caption checks remain pending until performed.

Ask for final push/PR/merge/settings authorization only after the candidate and verification report are concrete. Do not end early just because that future approval will be needed.

## 8. Required implementation deliverables and final response

Produce the implemented source/docs/scripts/workflow changes required by the plan and create:

`docs/publication/REPO_PUBLICATION_VERIFICATION_REPORT.md`

The report must contain:

1. Baseline and candidate identities, original-state preservation evidence and exact changed-file summary.
2. Task-ID completion matrix, approved scope reductions/deferred work, and reasons.
3. Verification matrix with commands/environments/results/counts/artifacts, failures/retries and cold-vs-warm/native-vs-mock boundaries.
4. README command verification, docs/link/diagram checks and license/notice status.
5. Original/public-derived evidence identities, exports approved, raw-data availability limitations and supported/unsupported claims.
6. Remaining defects, environmental limitations, owner decisions and publication blockers.
7. Concrete PR title/body/integration plan, with explicit committed/pushed/merged/settings state and authorization used.

Update `MAIN_PUBLICATION_CHECKLIST.md` only from evidence. Keep license choice, restricted evidence export, human alignment, remote checks, main integration, anonymous browser and caption consistency unchecked when unresolved. No supplied LinkedIn caption means NOT REVIEWED, not implicitly consistent.

Owner decisions may include license/scope, approved public derivatives/hosting, validated-accuracy vs conditional-methodology presentation, actual security-reporting contact, metadata changes and final external actions. Use conservative claims while preserving progress; do not invent approvals or stop all work on an unrelated pending decision.

Finish with: what changed and why; tests and evidence; regressions fixed; remaining risks/gates; candidate branch/diff/report paths; proposed PR summary; exact final owner action required. State clearly whether the result is locally verified, awaiting owner decisions, or actually integrated/public. Never report publication complete merely because the README looks finished.

Begin by reading the inputs and inspecting the current checkout, then carry the authorized local implementation through verification.
