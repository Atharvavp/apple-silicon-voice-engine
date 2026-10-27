# Main publication checklist

**Updated 2026-10-28 from the [verification report](REPO_PUBLICATION_VERIFICATION_REPORT.md) §15. Current verdict: NOT READY. PR #1 is open with green CI and awaits the owner's merge; public `main` is unchanged.**

Use with the [audit](REPO_PUBLICATION_AUDIT.md), [plan](REPO_PUBLICATION_PLAN.md), and implementation prompt (an internal working document, not published). Boxes are intentionally unchecked: passing checks on the local audit snapshot do not establish readiness of public `main`. Record a commit, date, environment and evidence link for every checked gate. Mark a conditional item “not applicable” with the narrower approved claim rather than silently checking it.

Candidate branch/commit: `publication/readiness` (last code commit `2f482e0`), pushed; [PR #1](https://github.com/Atharvavp/apple-silicon-voice-engine/pull/1). Items marked `5cd3f18` were verified on the pre-rewrite commit with the identical tree (`2f38aef`)\
Integrated main commit: _pending (not merged)_\
Verification date/environment: 2026-10-27, Apple M5 / macOS 26.6.2 / Swift 6.3.2 CLT / Python 3.12.14\
Selected publication scope: methodology-focused harness release; accuracy conditional (owner decision 2026-10-27); MIT license; evidence packet approved\
Final verification report: [REPO_PUBLICATION_VERIFICATION_REPORT.md](REPO_PUBLICATION_VERIFICATION_REPORT.md)

## 1. P0 blockers closed

- [ ] **F01:** public/default main contains the full reviewed harness, tests, schemas, configs, synthetic fixtures and intended corrections; it is no longer the initial README-only commit.
- [ ] **F02:** README and GitHub description accurately state benchmark-harness scope; integrated production voice engine, microphone and standalone VAD workflow are clearly planned.
- [ ] **F03:** owner has explicitly approved the project license and its code/docs/fixture scope; LICENSE and required third-party notices are present and accurate.
- [ ] No exposed credentials, unresolved redistribution issues, demonstrably false claims or broken primary quick-start commands remain.

## 2. Main branch and working-state integrity

- [x] Original owner modifications/untracked work were preserved and reviewed, with an explicit inclusion/disposition record. *(candidate `5cd3f18`: §2)*
- [x] Changed `Package.swift` and the required native test directory are included coherently; corrected results do not depend on omitted untracked review/follow-up files. *(candidate `5cd3f18`: §2–3)*
- [x] Candidate diff was reviewed against `main`; no accidental `diff.txt`, private inputs, full evidence tree, model/data assets, caches or generated exports were staged. *(candidate `5cd3f18`: §3, §12)*
- [x] Push/PR/integration were explicitly authorized before external action; no unapproved merge, branch deletion, force-push or history rewrite occurred. *(2026-10-28: push and PR authorized by the owner; the message-only rewrite was approved before it ran; only `publication/readiness` was pushed, without force; no merge or deletion)*
- [x] Commit attribution audited: all PR commits are authored and committed by `Atharvavp` (linked GitHub account); the AI co-author trailer was removed from all 22 earlier commits with owner approval, trees identical *(report §15; remote `imp/phase-0` still has 3 pre-rewrite commits, an owner decision)*
- [ ] Intended candidate changes are fully integrated into authoritative `main`, with recorded commit/check URLs.
- [ ] Fresh main checkout has clean tracked status; no required assets exist only uncommitted/untracked or under an author's ignored directory.
- [x] Default setup/build/smoke does not rewrite the intended root lock or source files. Ignored generated output is intentional and documented. *(candidate `5cd3f18`: §6)*

## 3. README, architecture and navigation

- [x] A first-time reader can understand the current project, motivation and supported first action from the opening paragraph/status. *(candidate `5cd3f18`: README)*
- [x] Implemented/mock/optional-native/planned capabilities are distinguished consistently. *(candidate `5cd3f18`: README, docs)*
- [x] Requirements separate observed environment, manifest deployment floors, optional SDK floors and untested combinations. *(candidate `5cd3f18`: README)*
- [x] Setup precedes run commands; Python 3.12 is explicit without requiring the author's absolute Homebrew path. *(candidate `5cd3f18`: README, §6)*
- [x] Minimal example uses committed synthetic tones/silence; success, output locations and mock scores are explained. *(candidate `5cd3f18`: README, §6)*
- [x] Comparison examples create both input runs before comparing; repeated-run/output refusal is explained. *(candidate `5cd3f18`: §6)*
- [x] Architecture diagram matches spool → replay → FIFO → sequential role calls → artifacts → Python scoring/validation/seal; no unsupported mic/VAD/simultaneous inference edge. *(candidate `5cd3f18`: §8 (source-checked; rendering separate))*
- [ ] The architecture diagram (static SVG since 2026-10-28; it replaced the planned Mermaid chart) renders correctly on GitHub in light and dark mode and has a readable prose fallback. *(partial: assets served as image/svg+xml and the `<picture>` markup is present on the PR branch; a visual check in both themes is NOT VERIFIED)*
- [x] Current architecture, CLI, contracts, evaluation, adapter, dependency and development documents are discoverable through relative links. *(candidate `5cd3f18`: docs/README.md)*
- [x] Historical Phase 0 readiness, milestone logs, prior reviews and superseded results are clearly dated/labelled; useful history and report-generator inputs are preserved. *(candidate `5cd3f18`: docs/README.md)*
- [ ] Relative paths, anchors, external source links and GitHub rendering have been checked; visitor-critical evidence references are accessible or explicitly unavailable.
- [ ] CONTRIBUTING and proportionate SECURITY guidance contain working commands and a real owner-approved reporting route.

## 4. Clean-clone setup and smoke

- [x] A fresh candidate/main clone was used, with a newly created Python environment and no required original-checkout symlinks/untracked files. *(candidate `5cd3f18`: §6 (candidate; warm caches))*
- [x] Hash-locked dependency installation and `pip check` passed on the stated supported Mac; interpreter/toolchain/dependency hashes are recorded. *(candidate `5cd3f18`: §6)*
- [x] Setup detects wrong Python/unsupported host and preserves existing incompatible environments with actionable diagnostics. *(candidate `5cd3f18`: §6)*
- [x] Initial network installation and separate optional model/data acquisition are distinguished from local/network-denied execution. *(candidate `5cd3f18`: README, phase1 guide)*
- [x] Default Swift build and release build pass; repeated default build leaves tracked lock/source unchanged. *(candidate `5cd3f18`: §6)*
- [x] Beginner smoke completes with no models, large downloads, AMI/account requirements or microphone input. *(candidate `5cd3f18`: §6)*
- [x] Smoke confirms completed state, mock flags, all 192,000 fixture samples consumed, zero drops, valid outputs and successful validation. *(candidate `5cd3f18`: §6)*
- [x] Validation/export work and produce the documented JSON/CSV/PNG files; expected machine-dependent values are not hard-coded as universal promises. *(candidate `5cd3f18`: §6)*
- [x] Repeated smoke allocates new output or refuses safely; populated sentinel directories remain byte-identical. *(candidate `5cd3f18`: §6)*
- [x] Every advertised README command was executed in order, with exact command/environment/exit/evidence recorded. Proposed/unverified commands are not presented as tested. *(candidate `5cd3f18`: §6)*

## 5. Tests, automation and platform honesty

- [x] Full Swift model-free suite passes using the documented toolchain/CLT wrapper. *(candidate `5cd3f18`: §6)*
- [x] **F08:** the 391.7 ms cancellation failure against a 200 ms bound was diagnosed and a reliable cancellation correctness gate defined; failed baseline was retained, not hidden by retries/skips. *(candidate `5cd3f18`: §7)*
- [x] Full Python suite, including real Swift parity/CLI checks, passes; no missing binary silently skips mandatory checks. *(candidate `5cd3f18`: §6)*
- [x] Doctor, shared schema corpus and supported-host fixture byte verification pass. *(candidate `5cd3f18`: §6)*
- [x] Release e2e checks pass into a new safe output; expected negative exits are validated. *(candidate `5cd3f18`: §6)*
- [x] Portable Python CI actually passed on its stated Linux environment/subset/dependencies; it is not described as Swift/Core ML/native-inference validation. *(runs 40590411586 @ `b94c80c` and 40592913631 @ `2f482e0`: ubuntu-24.04 x64, Python 3.12.15, hash-locked install, 70 passed, schema 133)*
- [x] macOS CI passed on its reported architecture/toolchain for declared mock-harness scope, or an honest manual gate/runner limitation is visible without a misleading badge. *(run 40592913631 @ `2f482e0`: macos-26-arm64, Xcode 26.6, Swift 6.3.3: 212 Swift, 289 Python, fixtures 55/0, smoke, tracked files unchanged; after three test/script fixes, report §15)*
- [x] Workflow permissions, caches, timeouts, triggers and artifact uploads are proportionate; no untrusted-PR privileged self-hosted model job or private-data upload. *(candidate `5cd3f18`: ci.yml (not yet run))*
- [x] Optional SDK build/stub tests have exact evidence before any claim that the current candidate's native SDK integration was tested. *(candidate `5cd3f18`: §6)*
- [x] Real-model smoke/campaign status is separately recorded as executed, historical, blocked or not run; mocks/stub MLModels do not count as real inference. *(candidate `5cd3f18`: §7, §11)*
- [x] Badges correspond to actual successful workflows on the intended branch; checks not run are not labelled pass. *(candidate `5cd3f18`: no badge added)*
- [x] Optional TSan/offline/long characterization checks are reported accurately; historical passes are not copied as fresh executions. *(candidate `5cd3f18`: §7 (not rerun; not claimed))*

## 6. Optional real-model reproducibility

- [x] Complete Phase 1 input template has all four rows, no ellipses, explicit pending/false example acceptance, and no private root paths/authorization notes. *(candidate `5cd3f18`: §4 T22)*
- [x] Exact SDK/source/model revisions, selected file sets/hashes, load paths, geometry, compute-unit requests and data/reference policy are documented. *(candidate `5cd3f18`: phase1 guide, packet)*
- [x] Original both-graph lock is preserved with correct SHA; default graph policy and isolated optional build instructions prevent unreviewed dependency drift. *(candidate `5cd3f18`: §6, §9)*
- [x] speech-swift path source/actual two-file patch is authenticated separately from `Package.resolved`; current vendor inventory describes real bytes and historical discrepancy remains acknowledged. *(candidate `5cd3f18`: §4 T41)*
- [x] Model/data acquisition instructions cite revision-specific primary rights/provenance, budgets and cache/disk/network constraints; no blanket acceptance or hidden downloader in the scoring environment. *(candidate `5cd3f18`: phase1 guide)*
- [x] `INPUTS`, `SESSION` and binary paths are initialized/quoted; fresh-output rules, missing-prerequisite statuses and sandbox requirements are explicit. *(candidate `5cd3f18`: phase1 guide)*
- [x] Real-model smoke/negative-control and measured recipes are distinct; any unexecuted recipe is labelled and not advertised as a completed reproduction. *(candidate `5cd3f18`: phase1 guide)*
- [x] A source rebuild is distinguished from exact historical binary identity. No benchmark rerun/download occurred without the corresponding authorization. *(candidate `5cd3f18`: §6, §11)*

## 7. Results evidence and scientific claims

- [x] Canonical results use the corrected narrative and retain visible corrections/history. *(candidate `5cd3f18`: PHASE_1_RESULTS.md)*
- [x] README figures/claims link to a reviewed small public evidence packet, or numeric headlines are withheld with evidence availability clearly stated. *(candidate `5cd3f18`: README, §9)*
- [x] Per-run/aggregate values, median/min/max, units, policy versions, repetitions and input identities agree with original artifacts. *(candidate `5cd3f18`: §9)*
- [x] Original sealed bytes remain unchanged; any redacted/public derivative has its own hash and does not masquerade as the original seal. *(candidate `5cd3f18`: §2, §9)*
- [x] Public provenance identifies hardware/OS/toolchain, framework/model/patch/lock/schema/binary, AMI source/crop/reference hashes, replay pacing, frame size, queue policy and role selection. *(candidate `5cd3f18`: packet README)*
- [x] Four configurations × three fresh processes is labelled one active role per run on one meeting; identical output across repetitions does not imply accuracy variance/generalization evidence. *(candidate `5cd3f18`: README, packet)*
- [x] Execution COMPLETE and reference/scientific validity are separate. Failed RMS check/no listening status is visible unless actual new manual evidence changes it. *(candidate `5cd3f18`: benchmarking.md, packet)*
- [x] Manual alignment gate is completed with owner observations **or** approved publication keeps accuracy conditional and avoids validated-accuracy/winner headlines. *(candidate `5cd3f18`: owner chose conditional)*
- [x] Custom recording-text/word-union references, zero collar/overlap/UEM and normalization are explicit; scores are not compared with standard AMI numbers without justification. *(candidate `5cd3f18`: benchmarking.md)*
- [x] Service RTF is not inverted into saturated throughput; no “11–13x faster” claim remains current. *(candidate `5cd3f18`: README, benchmarking.md)*
- [x] No word/EOU latency, online diarization-label latency, observed ANE/GPU placement, power, model-only memory or isolated cold-start claim exceeds available measurements. *(candidate `5cd3f18`: README, §11)*
- [x] A2 native limitations, conversion/postprocessing confounds, single-meeting/training-overlap caveats and unexplained memory variation remain clear. *(candidate `5cd3f18`: results, packet)*
- [x] Missing public raw data/reference evidence and limits on independent recomputation are stated; summaries are not called a full reproduction bundle unless they actually are one. *(candidate `5cd3f18`: §10, packet)*

## 8. Security, privacy and rights

- [x] Bounded credential scan of intended tracked tree/relevant reachable history completed; scan scope/limitations documented and no secret values printed. *(candidate `5cd3f18`: §6)*
- [x] Any actual credential exposure was contained/rotated with owner involvement; history cleanup, if needed, separately authorized. Removing current-tree text was not treated as sufficient containment. *(not applicable: the bounded scans found no credential)*
- [x] No private recordings, full AMI crop, weights, proprietary checkpoints, owner input/authorization file or private transcript/log output is in the intended publication tree without explicit rights/export approval. *(candidate `5cd3f18`: §2, §9)*
- [x] Curated evidence was reviewed for absolute personal paths, machine/private metadata, transcript text, emails and accidental credentials. *(candidate `5cd3f18`: §9)*
- [ ] Project license and all required third-party notices approved; optional SDK/path dependencies and embedded notices are accounted for as applicable to distributed artifacts.
- [x] Dataset/model original-checkpoint and conversion terms are distinguished; local use acceptance is not misrepresented as asset redistribution approval. *(candidate `5cd3f18`: THIRD_PARTY_NOTICES.md)*
- [x] Synthetic fixture license metadata and generator agree with approved terms; fixture/reference bytes and historical manifests remain consistent. *(candidate `5cd3f18`: §4 T11)*
- [x] SECURITY/CLI docs identify trusted-local-run assumptions, frozen executable paths, output-write behavior and privacy boundaries without unsupported sandbox guarantees. *(candidate `5cd3f18`: SECURITY.md, cli.md)*
- [x] Generated exports/comparisons/private inputs/work files are ignored narrowly; intentional malformed WAV and absolute-path schema fixtures remain tracked. *(candidate `5cd3f18`: §6)*

## 9. GitHub presentation and public access

- [x] Repository name/URL decision recorded; no unnecessary rename or visibility change. *(candidate `5cd3f18`: §13 (name kept))*
- [ ] Description/topics/homepage choices are accurate and owner-authorized; README no longer conflicts with metadata.
- [ ] Default branch is main and public repository/source/docs/approved evidence resolve without author assistance.
- [ ] Main commit and successful applicable checks are visible through the final public URL.
- [ ] Branch protection/ruleset policy was reviewed with suitable access; the audit's 403 has not been treated as proof of absence.
- [ ] README links, license display, diagram, optional figures and badges work in actual GitHub rendering.
- [ ] Final URL was opened in an anonymous/incognito browser; authenticated connector access alone was not substituted for this check.
- [x] Release/tag/social-preview assets are either deliberately omitted or separately reviewed/authorized; no invented release milestone. *(candidate `5cd3f18`: omitted)*

## 10. LinkedIn consistency and owner signoff

- [ ] The actual accompanying caption has been supplied and reviewed; if absent, status remains **NOT REVIEWED**.
- [ ] Caption describes a benchmark harness and planned engine accurately; no combined real-model or production-readiness implication.
- [ ] Each numeric/qualitative claim points to public evidence with matching units, role, host, pacing, policy and caveats.
- [ ] No withdrawn throughput, validated-alignment, causal-framework/quantization, ANE/power or model-only-memory claim appears.
- [ ] The shared URL lands on the reviewed default-main repository rather than an inaccessible local/unpublished branch.
- [x] Final verification report lists completed task IDs, commands/results, failed/retried checks, scope limitations and all remaining owner decisions. *(candidate `5cd3f18`: report)*
- [ ] Owner has approved the concrete integrated/public result and the final sharing action; any unresolved required gate keeps the verdict NOT READY.

Final verdict: **NOT READY** (2026-10-27). The candidate is locally verified. Nothing is on public `main` yet.\
Outstanding blockers: the owner's merge of PR #1; after the merge, a visual rendering check (both themes), the license display, the description/topics (the live description still overclaims), a protection review and an incognito check; the security reporting route; caption review (NOT REVIEWED). The owner's 2026-10-28 brief names the owner as Atharva Pawar, which matches the LICENSE copyright line.\
Accepted scope reductions: accuracy conditional (no README headline); evidence figures omitted; T52 deferred; no real-model run in this session.\
Owner approval/date: decisions of 2026-10-27 recorded in the report §5. Final publication approval is _pending_.
