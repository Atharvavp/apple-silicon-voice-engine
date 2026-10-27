# Main publication checklist

**Plan-stage draft — 2026-10-27, Asia/Kolkata. Current verdict: NOT READY.**

Use with the [audit](REPO_PUBLICATION_AUDIT.md), [plan](REPO_PUBLICATION_PLAN.md), and [implementation prompt](REPO_PUBLICATION_IMPLEMENTATION_PROMPT.md). Boxes are intentionally unchecked: passing checks on the local audit snapshot do not establish readiness of public `main`. Record a commit, date, environment and evidence link for every checked gate. Mark a conditional item “not applicable” with the narrower approved claim rather than silently checking it.

Candidate branch/commit: _pending_  
Integrated main commit: _pending_  
Verifier/date/environment: _pending_  
Selected publication scope: _pending owner decision_  
Final verification report: _created during implementation_

## 1. P0 blockers closed

- [ ] **F01:** public/default main contains the full reviewed harness, tests, schemas, configs, synthetic fixtures and intended corrections; it is no longer the initial README-only commit.
- [ ] **F02:** README and GitHub description accurately state benchmark-harness scope; integrated production voice engine, microphone and standalone VAD workflow are clearly planned.
- [ ] **F03:** owner has explicitly approved the project license and its code/docs/fixture scope; LICENSE and required third-party notices are present and accurate.
- [ ] No exposed credentials, unresolved redistribution issues, demonstrably false claims or broken primary quick-start commands remain.

## 2. Main branch and working-state integrity

- [ ] Original owner modifications/untracked work were preserved and reviewed, with an explicit inclusion/disposition record.
- [ ] Changed `Package.swift` and the required native test directory are included coherently; corrected results do not depend on omitted untracked review/follow-up files.
- [ ] Candidate diff was reviewed against `main`; no accidental `diff.txt`, private inputs, full evidence tree, model/data assets, caches or generated exports were staged.
- [ ] Push/PR/integration were explicitly authorized before external action; no unapproved merge, branch deletion, force-push or history rewrite occurred.
- [ ] Intended candidate changes are fully integrated into authoritative `main`, with recorded commit/check URLs.
- [ ] Fresh main checkout has clean tracked status; no required assets exist only uncommitted/untracked or under an author's ignored directory.
- [ ] Default setup/build/smoke does not rewrite the intended root lock or source files. Ignored generated output is intentional and documented.

## 3. README, architecture and navigation

- [ ] A first-time reader can understand the current project, motivation and supported first action from the opening paragraph/status.
- [ ] Implemented/mock/optional-native/planned capabilities are distinguished consistently.
- [ ] Requirements separate observed environment, manifest deployment floors, optional SDK floors and untested combinations.
- [ ] Setup precedes run commands; Python 3.12 is explicit without requiring the author's absolute Homebrew path.
- [ ] Minimal example uses committed synthetic tones/silence; success, output locations and mock scores are explained.
- [ ] Comparison examples create both input runs before comparing; repeated-run/output refusal is explained.
- [ ] Architecture diagram matches spool → replay → FIFO → sequential role calls → artifacts → Python scoring/validation/seal; no unsupported mic/VAD/simultaneous inference edge.
- [ ] Mermaid renders correctly on GitHub and has a readable prose fallback.
- [ ] Current architecture, CLI, contracts, evaluation, adapter, dependency and development documents are discoverable through relative links.
- [ ] Historical Phase 0 readiness, milestone logs, prior reviews and superseded results are clearly dated/labelled; useful history and report-generator inputs are preserved.
- [ ] Relative paths, anchors, external source links and GitHub rendering have been checked; visitor-critical evidence references are accessible or explicitly unavailable.
- [ ] CONTRIBUTING and proportionate SECURITY guidance contain working commands and a real owner-approved reporting route.

## 4. Clean-clone setup and smoke

- [ ] A fresh candidate/main clone was used, with a newly created Python environment and no required original-checkout symlinks/untracked files.
- [ ] Hash-locked dependency installation and `pip check` passed on the stated supported Mac; interpreter/toolchain/dependency hashes are recorded.
- [ ] Setup detects wrong Python/unsupported host and preserves existing incompatible environments with actionable diagnostics.
- [ ] Initial network installation and separate optional model/data acquisition are distinguished from local/network-denied execution.
- [ ] Default Swift build and release build pass; repeated default build leaves tracked lock/source unchanged.
- [ ] Beginner smoke completes with no models, large downloads, AMI/account requirements or microphone input.
- [ ] Smoke confirms completed state, mock flags, all 192,000 fixture samples consumed, zero drops, valid outputs and successful validation.
- [ ] Validation/export work and produce the documented JSON/CSV/PNG files; expected machine-dependent values are not hard-coded as universal promises.
- [ ] Repeated smoke allocates new output or refuses safely; populated sentinel directories remain byte-identical.
- [ ] Every advertised README command was executed in order, with exact command/environment/exit/evidence recorded. Proposed/unverified commands are not presented as tested.

## 5. Tests, automation and platform honesty

- [ ] Full Swift model-free suite passes using the documented toolchain/CLT wrapper.
- [ ] **F08:** the 391.7 ms cancellation failure against a 200 ms bound was diagnosed and a reliable cancellation correctness gate defined; failed baseline was retained, not hidden by retries/skips.
- [ ] Full Python suite, including real Swift parity/CLI checks, passes; no missing binary silently skips mandatory checks.
- [ ] Doctor, shared schema corpus and supported-host fixture byte verification pass.
- [ ] Release e2e checks pass into a new safe output; expected negative exits are validated.
- [ ] Portable Python CI actually passed on its stated Linux environment/subset/dependencies; it is not described as Swift/Core ML/native-inference validation.
- [ ] macOS CI passed on its reported architecture/toolchain for declared mock-harness scope, or an honest manual gate/runner limitation is visible without a misleading badge.
- [ ] Workflow permissions, caches, timeouts, triggers and artifact uploads are proportionate; no untrusted-PR privileged self-hosted model job or private-data upload.
- [ ] Optional SDK build/stub tests have exact evidence before any claim that the current candidate's native SDK integration was tested.
- [ ] Real-model smoke/campaign status is separately recorded as executed, historical, blocked or not run; mocks/stub MLModels do not count as real inference.
- [ ] Badges correspond to actual successful workflows on the intended branch; checks not run are not labelled pass.
- [ ] Optional TSan/offline/long characterization checks are reported accurately; historical passes are not copied as fresh executions.

## 6. Optional real-model reproducibility

- [ ] Complete Phase 1 input template has all four rows, no ellipses, explicit pending/false example acceptance, and no private root paths/authorization notes.
- [ ] Exact SDK/source/model revisions, selected file sets/hashes, load paths, geometry, compute-unit requests and data/reference policy are documented.
- [ ] Original both-graph lock is preserved with correct SHA; default graph policy and isolated optional build instructions prevent unreviewed dependency drift.
- [ ] speech-swift path source/actual two-file patch is authenticated separately from `Package.resolved`; current vendor inventory describes real bytes and historical discrepancy remains acknowledged.
- [ ] Model/data acquisition instructions cite revision-specific primary rights/provenance, budgets and cache/disk/network constraints; no blanket acceptance or hidden downloader in the scoring environment.
- [ ] `INPUTS`, `SESSION` and binary paths are initialized/quoted; fresh-output rules, missing-prerequisite statuses and sandbox requirements are explicit.
- [ ] Real-model smoke/negative-control and measured recipes are distinct; any unexecuted recipe is labelled and not advertised as a completed reproduction.
- [ ] A source rebuild is distinguished from exact historical binary identity. No benchmark rerun/download occurred without the corresponding authorization.

## 7. Results evidence and scientific claims

- [ ] Canonical results use the corrected narrative and retain visible corrections/history.
- [ ] README figures/claims link to a reviewed small public evidence packet, or numeric headlines are withheld with evidence availability clearly stated.
- [ ] Per-run/aggregate values, median/min/max, units, policy versions, repetitions and input identities agree with original artifacts.
- [ ] Original sealed bytes remain unchanged; any redacted/public derivative has its own hash and does not masquerade as the original seal.
- [ ] Public provenance identifies hardware/OS/toolchain, framework/model/patch/lock/schema/binary, AMI source/crop/reference hashes, replay pacing, frame size, queue policy and role selection.
- [ ] Four configurations × three fresh processes is labelled one active role per run on one meeting; identical output across repetitions does not imply accuracy variance/generalization evidence.
- [ ] Execution COMPLETE and reference/scientific validity are separate. Failed RMS check/no listening status is visible unless actual new manual evidence changes it.
- [ ] Manual alignment gate is completed with owner observations **or** approved publication keeps accuracy conditional and avoids validated-accuracy/winner headlines.
- [ ] Custom recording-text/word-union references, zero collar/overlap/UEM and normalization are explicit; scores are not compared with standard AMI numbers without justification.
- [ ] Service RTF is not inverted into saturated throughput; no “11–13x faster” claim remains current.
- [ ] No word/EOU latency, online diarization-label latency, observed ANE/GPU placement, power, model-only memory or isolated cold-start claim exceeds available measurements.
- [ ] A2 native limitations, conversion/postprocessing confounds, single-meeting/training-overlap caveats and unexplained memory variation remain clear.
- [ ] Missing public raw data/reference evidence and limits on independent recomputation are stated; summaries are not called a full reproduction bundle unless they actually are one.

## 8. Security, privacy and rights

- [ ] Bounded credential scan of intended tracked tree/relevant reachable history completed; scan scope/limitations documented and no secret values printed.
- [ ] Any actual credential exposure was contained/rotated with owner involvement; history cleanup, if needed, separately authorized. Removing current-tree text was not treated as sufficient containment.
- [ ] No private recordings, full AMI crop, weights, proprietary checkpoints, owner input/authorization file or private transcript/log output is in the intended publication tree without explicit rights/export approval.
- [ ] Curated evidence was reviewed for absolute personal paths, machine/private metadata, transcript text, emails and accidental credentials.
- [ ] Project license and all required third-party notices approved; optional SDK/path dependencies and embedded notices are accounted for as applicable to distributed artifacts.
- [ ] Dataset/model original-checkpoint and conversion terms are distinguished; local use acceptance is not misrepresented as asset redistribution approval.
- [ ] Synthetic fixture license metadata and generator agree with approved terms; fixture/reference bytes and historical manifests remain consistent.
- [ ] SECURITY/CLI docs identify trusted-local-run assumptions, frozen executable paths, output-write behavior and privacy boundaries without unsupported sandbox guarantees.
- [ ] Generated exports/comparisons/private inputs/work files are ignored narrowly; intentional malformed WAV and absolute-path schema fixtures remain tracked.

## 9. GitHub presentation and public access

- [ ] Repository name/URL decision recorded; no unnecessary rename or visibility change.
- [ ] Description/topics/homepage choices are accurate and owner-authorized; README no longer conflicts with metadata.
- [ ] Default branch is main and public repository/source/docs/approved evidence resolve without author assistance.
- [ ] Main commit and successful applicable checks are visible through the final public URL.
- [ ] Branch protection/ruleset policy was reviewed with suitable access; the audit's 403 has not been treated as proof of absence.
- [ ] README links, license display, diagram, optional figures and badges work in actual GitHub rendering.
- [ ] Final URL was opened in an anonymous/incognito browser; authenticated connector access alone was not substituted for this check.
- [ ] Release/tag/social-preview assets are either deliberately omitted or separately reviewed/authorized; no invented release milestone.

## 10. LinkedIn consistency and owner signoff

- [ ] The actual accompanying caption has been supplied and reviewed; if absent, status remains **NOT REVIEWED**.
- [ ] Caption describes a benchmark harness and planned engine accurately; no combined real-model or production-readiness implication.
- [ ] Each numeric/qualitative claim points to public evidence with matching units, role, host, pacing, policy and caveats.
- [ ] No withdrawn throughput, validated-alignment, causal-framework/quantization, ANE/power or model-only-memory claim appears.
- [ ] The shared URL lands on the reviewed default-main repository rather than an inaccessible local/unpublished branch.
- [ ] Final verification report lists completed task IDs, commands/results, failed/retried checks, scope limitations and all remaining owner decisions.
- [ ] Owner has approved the concrete integrated/public result and the final sharing action; any unresolved required gate keeps the verdict NOT READY.

Final verdict: _NOT READY / READY WITH FIXES / READY — fill only after evidence review_  
Outstanding blockers/accepted scope reductions: _pending_  
Owner approval/date: _pending_
