# Repository publication verification report

Prepared 2026-10-27 (Asia/Kolkata) for the owner. It records the implementation of
[REPO_PUBLICATION_PLAN.md](REPO_PUBLICATION_PLAN.md) on a local candidate branch.

**State: LOCALLY VERIFIED, AWAITING OWNER DECISIONS AND EXTERNAL ACTIONS. Not pushed, not merged,
not public.** Public `main` is still the two-line initial README.

## 1. Baseline and candidate identities

| | Value |
|---|---|
| Original checkout | `/Users/atharvapawar/workspace/content/linkedin/apple-silicon-voice-engine`, branch `imp/phase-1`, HEAD `e29f345abbdaa68cd496955b5e00f3fed86b140d`, dirty (4 modified, 9 untracked paths) |
| `main` / `origin/main` | `4a5d3abf5f5c42dfb873737b89ebbe58237b5a60` (initial commit, README only), an ancestor of the candidate, so a fast-forward is possible |
| Remote | `https://github.com/Atharvavp/apple-silicon-voice-engine.git` (no embedded credentials) |
| Candidate branch | `publication/readiness`, local only, in a separate worktree: `/Users/atharvapawar/workspace/content/linkedin/apple-silicon-voice-engine-publication` |
| Candidate HEAD | see §13 (14 commits on top of `e29f345`; 19 commits ahead of `main`) |
| Host used | Apple M5 (Mac17,3), macOS 26.6.2 (25G83), arm64. Swift 6.3.2 with Command Line Tools only. Python 3.12.14 (`/opt/homebrew/bin/python3.12`); ambient `python3` is 3.14.7 |

The audit's baseline facts were re-observed and matched: branch, HEAD, `main`, the four modified and
nine untracked paths, and the root lock SHA `aee60879…`. Differences from the audit: none affecting
the plan. New findings during implementation are listed in §12.

## 2. Preservation of the original working state

- Before any work, the SHA-256 of all 20 pre-existing changed or untracked files (including
  `diff.txt` and `Package.resolved`) was recorded outside the tree. After all the work, `shasum -c`
  matched for all 20, `git status` was identical to the baseline and HEAD was unchanged. Nothing was
  stashed, reset, cleaned or bulk-staged in the original checkout.
- Owner work was copied into the candidate byte-identically (hash-verified) and committed as two
  commits. The first holds the Phase 1 follow-up Step 0 work: `Package.swift` test target,
  `Tests/SpeechNativeEOUTests/`, `scripts/report_phase1.py`, `scripts/phase1_followup/`, the
  follow-up audit test, the corrected results, the review, the follow-up plan/results and
  `docs/phase1/history/`. The second holds the four `docs/publication/` planning records.
- **Excluded on purpose:** `diff.txt` (local work file; now also ignored), all of root `evidence/`
  (2.4 GB for s2; only the approved packet was derived from it), `vendor/`, `.build/`, `.venv/`, the
  private `phase1-inputs.json`, model files and AMI data.
- The 623 files of `evidence/phase1/one-shot/20261021-s2/` were hashed before and after the packet
  export, and the listings were identical. The original `vendor/speech-swift` was only read
  (`git -C … rev-parse/diff/status`, `verify-speech`), and its status was unchanged afterwards.

## 3. Changed files (candidate vs `e29f345`: 65 files, +7,673 / −646)

| Group | Files |
|---|---|
| Owner work carried over | `Package.swift` (test target), `Tests/SpeechNativeEOUTests/*`, `scripts/report_phase1.py`, `scripts/phase1_followup/*`, `analysis/tests/test_phase1_followup_audit.py`, `docs/phase1/{PHASE_1_RESULTS,README,CODEX_INDEPENDENT_REVIEW,PHASE_1_FOLLOWUP_PLAN,PHASE_1_FOLLOWUP_RESULTS}.md`, `docs/phase1/history/*`, `docs/publication/{AUDIT,PLAN,PROMPT,CHECKLIST}` |
| Lock and manifest | `Package.resolved` (default graph, 2 pins), `Package.swift` (one stale comment) |
| New entrypoints | `scripts/setup.sh`, `scripts/smoke.sh`, `scripts/smoke_check.py`, `scripts/export_evidence_packet.py`, `scripts/check_phase1_assets.py` |
| Safe outputs | `scripts/{e2e,determinism,characterize,acceptance,checkpoint}.py`, `scripts/offline_smoke.sh`, `.gitignore` |
| Vendor identity | `scripts/run_phase1.py` (`verify-speech`, richer new vendor record) |
| Tests | `Tests/ReplayTests/{ReplayModeTests,TestSupport}.swift`, `Tests/TelemetryTests/TelemetryTests.swift`, `analysis/tests/{test_publication_scripts,test_phase1_vendor}.py` |
| Rights | `LICENSE` (MIT), `THIRD_PARTY_NOTICES.md`, `scripts/generate_fixtures.py` + `datasets/manifests/synthetic.json` (rights text only) |
| Evidence | `docs/phase1/evidence/20261021-s2/*` (9 files, 104 KB), dated correction in `PHASE_1_RESULTS.md` |
| Docs | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/{README,architecture,benchmarking,development,roadmap}.md` (new), `docs/{cli,contracts,api-verification,dependencies,phase1-adapter-guide}.md`, `docs/phase1/README.md`, `docs/phase1/phase1-inputs.example.json` |
| CI | `.github/workflows/ci.yml`, `.github/pull_request_template.md` |

Byte-identical to `e29f345`: `schemas/`, `analysis/src/`, all of `Sources/`, `testdata/`,
`datasets/fixtures/`, `configs/`, `patches/`, `PHASE_0_READINESS_REPORT.md` and the Phase 0
reports and logs. The schema bundle SHA-256 is still
`cc647ac939b23f7721b5ca739b27538c3701702c7c691ffb3b9f2560a8918407`.

## 4. Task matrix

| Task | Status | Evidence |
|---|---|---|
| T00 baseline/preservation | **Verified** | §2 |
| T01 candidate assembly | **Verified** | 14 local commits; fresh clone contains full harness (§6) |
| T10 scope claims | **Verified** | README/docs rewritten; `rg` review of "fully on-device / faster than real time / simultaneous / ANE" hits: only corrections, caveats and dated history remain |
| T11 rights | **Verified locally; one confirmation pending** | MIT approved by owner 2026-10-27; `LICENSE`, `THIRD_PARTY_NOTICES.md`; fixture metadata updated with `--verify` 0 mismatches. Copyright holder written as "Atharva Pawar" (GitHub display name on the initial commit); **owner to confirm** |
| T12 results scope | **Verified (owner choice: conditional)** | No README accuracy headline; failed RMS check and missing listening check stated next to every score |
| T20 setup | **Verified** | Wrong interpreter, incompatible venv and unknown-argument refusals; real run twice (idempotent); fresh clone (§6) |
| T21 smoke | **Verified** | Two distinct outputs, sentinel refusal, accounting assertions with tamper negatives |
| T22 real-model recipe | **Verified as documentation and parser behavior; real-model stages NOT RUN** | Complete template; parsers block it with exact reasons; asset hash check 52/52 on the owner's existing assets; all cited subcommands/flags exist |
| T23 lock policy | **Verified** | Default build leaves lock unchanged (repeat builds, fresh clone); historical lock preserved byte-identical in the packet and reused for the both build with 0 pin changes |
| T30 README/docs | **Verified locally; GitHub rendering pending** | 128 relative links/anchors, 0 problems after the 2026-10-28 README revision; every README command executed (§6); SVG diagram rendered locally with Quick Look, GitHub rendering unchecked |
| T31 evidence packet | **Verified (owner approved)** | §9 |
| T32 historical labels/roadmap | **Verified** | `docs/README.md` index, `docs/roadmap.md`; historical bytes unchanged |
| T33 CONTRIBUTING/SECURITY | **Verified, with reporting route awaiting owner** | Route left pending by owner decision; no invented channel |
| T40 safe outputs/ignores | **Verified** | Sentinel tests for 7 scripts; mutation check against the old `e2e.py` showed deletion; ignore matches checked |
| T41 vendor identity | **Verified** | Original copy and a fresh fetch both pass `verify-speech`; stale record reported |
| T50 cancellation gate | **Verified** | §7 |
| T51 CI | **Defined and locally simulated; remote run pending** | Workflow parses; no push authorized, so no run and no badge |
| T52 report integrity hardening | **Deferred (optional)** | Not needed for the current valid packet; the packet exporter independently checks distinct (row, repetition) pairs, sealed hashes and recomputation |
| T60 fresh clone and integration prep | **Verified locally** | §6, §13 |
| T61 public main / LinkedIn | **Awaiting owner authorization** | Nothing pushed; caption NOT REVIEWED (none supplied) |

## 5. Owner decisions recorded (2026-10-27, this session)

| Decision | Answer | Applied |
|---|---|---|
| License | MIT | `LICENSE`, notices, fixture metadata |
| Evidence packet | Approved | `docs/phase1/evidence/20261021-s2/` (figures left out deliberately; owner may add) |
| Accuracy presentation | Conditional only | README carries no accuracy figures |
| Security reporting route | Leave pending | `SECURITY.md` says so; publication gate stays open |

## 6. Verification runs

All runs were on the host in §1. Environment for analysis steps: `PYTHONPATH=<checkout>/analysis/src`,
`MPLBACKEND=Agg`, `PYTHONDONTWRITEBYTECODE=1`, `PHASE1_FRAMEWORKS=none` unless stated. Lock hashes:
dev `bfaeff97…bbe`, runtime `75301ec0…5f5`. Root `Package.resolved` `618f25a5…590c` before and after.
Raw logs are in the session scratch directory, which is not durable. The material results are recorded here.

### Fresh clone of candidate `5cd3f18`, following the README in order

A new directory and a new `.venv`. No `.build`, `vendor`, `evidence` or symlinked venv was present.
The pip and SwiftPM caches were **warm** (41/41 wheels from cache).

| Step (cwd = clone root) | argv | Exit | Time | Result |
|---|---|---:|---:|---|
| clone | `git clone <candidate worktree>` (stand-in for the GitHub URL, which does not have the candidate yet) | 0 | 0 s | |
| README setup | `bash scripts/setup.sh` | 0 | 80 s | venv created, hash-locked install, `pip check`, doctor pass, release build |
| README smoke | `bash scripts/smoke.sh` | 0 | 5 s | completed, mock, 192,000/192,000 consumed, 0 dropped, validation pass, exports present |
| manual build | `PHASE1_FRAMEWORKS=none swift build --disable-keychain -c release` | 0 | 2 s | |
| version | `.build/release/voicebench --version` | 0 | 0 s | `0.7.0-phase0 (schema 1.0; phase1 frameworks: none)` |
| run / validate / export | the three README commands for `first-run` | 0/0/0 | 6 s | |
| second run, compare | README commands | 0/0 | 5 s | `compare (accuracy): compatible` |
| reuse refused | `voicebench run … --run-id first-run` again | **2** (expected) | 0 s | "run first-run already exists" |
| pip check | `.venv/bin/python -m pip check` | 0 | 0 s | |
| debug build | `swift build --disable-keychain` | 0 | 28 s | |
| Swift suite (parallel) | `bash scripts/swift_test.sh --disable-keychain` | 0 | 18 s | **212 tests in 42 suites passed** |
| Python suite | `.venv/bin/python -m pytest analysis/tests -q` | 0 | 85 s | **289 passed** (audit: 266, plus 17 publication and 6 vendor tests) |
| fixture bytes | `scripts/generate_fixtures.py --small --out datasets/fixtures --verify` | 0 | 0 s | 55 files, 0 mismatches |
| doctor | `-m phase0_analysis doctor --schemas schemas/v1 --project-root . --out <scratch>` | 0 | 1 s | pass |
| schema corpus | `-m phase0_analysis schema-check --schemas schemas/v1 --fixtures testdata/schemas --out <scratch>` | 0 | 1 s | 133 documents, 0 unexpected |
| release e2e | `scripts/e2e.py --voicebench .build/release/voicebench --out <new scratch dir>` | 0 | 71 s | **45/45**, including the expected negative exits |
| setup rerun | `bash scripts/setup.sh` | 0 | 3 s | idempotent |
| tracked status after all of the above | `git status --porcelain` | — | — | **empty**; ignored only: `.build/ .venv/ runs/ exports/ comparisons/` |

### Other checks (candidate worktree or disposable checkouts)

| Check | Result |
|---|---|
| Parallel Swift suite before T50 (with `.venv`), 5 runs | 5/5 pass (211 tests). The flaky bound did not trip in these 5; see §7 for the 10-run latency distribution |
| Parallel Swift suite after T50, 10 runs | 10/10 pass, 212 tests |
| Strict cancellation target, filtered, `VOICEBENCH_TIMING_CHECKS=1`, 5 runs | 5/5 pass, 0.17–0.24 ms |
| Default build twice, plus a fresh probe resolve | `Package.resolved` unchanged (`618f25a5…`) |
| `setup.sh` with Python 3.14, an existing 3.14 venv, an unknown argument | refused before any change; the venv stayed byte-identical |
| New tests `test_publication_scripts.py` (17), `test_phase1_vendor.py` (6) | pass. A mutation check against the old `e2e.py` confirmed it deletes the sentinel |
| Optional both-graph build in a disposable clone: fresh `vendor-speech`, `verify-speech`, historical lock | build pass (205 s), lists both frameworks, 41 pins with 0 differences, binary `a1b5303c…` |
| Both-graph Swift suite (stub models) | 220 tests pass, 5 known issues (documented native EOU cases) |
| Python suite against the both-graph binary | 289 passed |
| Portable subset with the CLI hidden (`VOICEBENCH_BIN=/nonexistent`), macOS | 70 passed; the schema corpus passed |
| Linux install of the hash lock | **Inconclusive, not verified.** The lock carries hashes for every wheel of each pinned release (numpy alone has 66), so a hash-checked Linux install is plausible. A local `pip install --dry-run --platform manylinux…_x86_64 --require-hashes` attempt was stopped after 16 min of repeatedly interrupted downloads. The first `python-portable` CI run is the real test. If it fails, add a separately generated Linux lock rather than dropping `--require-hashes` |
| Remote CI | **Not run** (push not authorized) |
| Secret scan, 494 reachable blobs on all local refs, plus the candidate tree | 4 pattern hits, all the same false positive (`version_token` literal); no credential found. Bounded pattern scan, not a certification. Unreachable objects and encoded secrets were not covered |
| Original checkout | 20/20 pre-existing files byte-identical; status and HEAD unchanged |


## 7. Failures, retries and boundaries

- **F08 cancellation (resolved without production changes).** In 10 parallel full-suite runs the
  candidate's real-clock cancellation latency was 30.2, 46.0, 81.2, 165.1, 168.8, 171.9, 185.7,
  191.7, 211.0 and 490.9 ms. Two of the 10 exceeded the old 200 ms bound, which matches the audit's
  391.7 ms failure. Five isolated runs gave 0.17–0.24 ms. The gate is now a deterministic test: a
  clock whose sleeps end only on cancellation, in realtime and accelerated modes. It is backed by a
  real-clock test on the 12 s fixture with a 5 s gate and a watchdog. The 200 ms target is opt-in
  (`VOICEBENCH_TIMING_CHECKS=1`), and it passed 5/5 isolated runs. Mutation checks: swallowing
  sleep errors is still caught, by the queue's own cancellation check (not a defect). Removing the
  queue's receive-side cancellation handler first **hung** the suite (I killed that run and restored
  the file), which exposed a weakness that the watchdog now closes: the same mutation now fails all
  three cases after 30 s.
- **Swift suite before `.venv` existed:** 70 issues in a new checkout. This was a missing
  prerequisite (tests run `<repo>/.venv/bin/python`), now documented. With setup done: 5/5 and
  10/10 parallel runs passed.
- **Optional both-graph Swift suite:** the first run had 1 real failure, `buildFactsComeFromTheCompiler`
  (hard-coded macOS 13). It was known since s1. I fixed the test to expect each graph's declared
  floor, and the rerun gave 220 passed with 5 known issues.
- **Packet exporter:** the first two attempts failed on my own wrong field assumptions. The third
  was stopped by the consistency guard, which found the `git_dirty` discrepancy (§12). None of them
  wrote output.
- **Linux lock dry-run:** a first attempt with only `manylinux_2_28` tags could not find
  `kiwisolver==1.5.1` (tag-selection artefact of an explicit `--platform`). A second attempt had a
  shell quoting error of mine. The third, with the full tag set, stalled on interrupted downloads
  and was stopped. Linux installability is therefore **unverified** (§6).
- **Mock vs native.** Every check here is mock or stub-model. **No real-model inference was run in
  this session.** The 2026-10-21 campaign is historical evidence, re-verified only by hashing and
  recomputation.
- **Cold vs warm.** The fresh clone used a new `.venv`, but pip and SwiftPM caches were warm (all
  41 wheels came from the pip cache), so this was not an empty-machine install.

## 8. README, documentation, link, diagram and notice checks

- Every README command was executed in a fresh clone in order (§6), including the second run
  before `compare`, and a reused run ID was refused.
- Relative links and anchors in all 33 Markdown files: 102 checked, 0 problems (GitHub slug rules).
- Architecture edges were checked against `Pipeline.swift` (ASR then diarization), `ExperimentRunner`
  (flush → shutdown → score → seal), `EventRecorder`/`JSONLStream` (bounded writes, separate
  telemetry stream) and `AnalysisCommands` (frozen interpreter for validate/compare/export).
- **Diagram.** Since the 2026-10-28 README revision, the architecture diagram is a static SVG,
  `docs/assets/architecture-{light,dark}.svg`, generated by `docs/assets/make_architecture_svg.py`.
  It has no scripts or external fonts and is shown through `<picture>` for light and dark mode.
  Both variants were well-formed (`xmllint`) and were rendered and inspected locally with Quick
  Look. GitHub's rendering (including `<picture>` and the `[!NOTE]`/`[!WARNING]` callouts) still
  needs a push. The previous Mermaid chart was removed, and the prose description of the data path
  is kept next to the image.
- The notices separate project MIT scope from the Apache-2.0 patch, the default and optional linked
  packages (taken from the historical binary's link file list), model terms and AMI CC BY 4.0. A
  full license-compatibility review of the optional graph was not performed.

## 9. Evidence identities and export approval

The packet `docs/phase1/evidence/20261021-s2/` was approved by the owner on 2026-10-27.

| File | SHA-256 | Origin |
|---|---|---|
| `results-per-run.csv` | `51c3b9a03b7a48bff7cbfd480b784c50ae236440d98ec0cf7f71dece5c6e6599` | byte copy of `report/results-per-run.csv` |
| `results-summary.csv` | `e07bb66a8698e728c17763773e5e229910ffd7ed17a7243baa3fc5afd35aa7b6` | byte copy of `report/results-summary.csv` |
| `report.json` | `d99f908be7e479977847b4a0860315cd73d63cc7bea75d1e5eb6d11b6075f56c` | byte copy of `report/report.json` |
| `Package.resolved.both` | `aee60879806d3b495c2794a43743114016a2803e8053d97fc350fc83644c2a3f` | byte copy of `build/Package.resolved.both` |
| `provenance.json` | `a82aa749e211aa33aea852814fa38142ec7cc98f884fc0471d58efacd3f1878c` | new derived file (redacted) |
| `recomputation.json` | `7901f5f0043f4d8c797661eb83e97daecbec3699cd3bd71402e62ec8138a8807` | new derived file |

Recomputation passed: 48 per-run accuracy values were re-read from sealed `metrics.json`, and 84
summary cells were re-derived with the report generator's `summarize()`/`fmt()`. There are 12
distinct (row, repetition) pairs. A privacy scan of the packet found no absolute paths, emails,
participant IDs, owner statements or raw power text. This is an integrity and arithmetic check that
reuses project code. It is not an independent scorer or a new inference run.

## 10. Raw-data limits

The packet omits audio, references (transcript text), predictions, event and telemetry traces,
model weights and the owner inputs file. As a result, WER/CER/DER/JER cannot be recomputed from
public data, timing and memory can be checked only at the per-run aggregate level, and outputs
cannot be regenerated without lawfully obtained AMI audio and models. The hashes let a third party
confirm local copies.

## 11. Supported and unsupported claims

Supported (with the stated caveats):
- The default build is a mock-only harness, and its smoke path consumes all 192,000 samples with
  zero drops and validates.
- Four optional real wrappers exist and compile at the stated pins. Their contract tests pass with
  stub models.
- In the historical campaign, 12/12 single-role runs at 1× pace completed and validated, each
  consuming 16,638,080 samples with 0 dropped. Accumulated active-adapter wall time was 79–90 s per
  1,039.88 s replay.

Unsupported: anything about an integrated or simultaneous engine. Also unsupported: throughput,
"x faster than real time", word/EOU/online-speaker latency, ANE/GPU placement, power, model-only or
total memory, validated or standard AMI accuracy, and framework or quantization winners. So are
platform compatibility beyond the one tested host, a fixed A2 SDK, a resolved alignment question,
and reproducible builds (the rebuilt both-graph binary hashes `a1b5303c…`, not `5f8ccfe3…`).

## 12. Remaining defects, findings and blockers

Findings from this session:
1. **Provenance discrepancy.** A1-rep3 and A2-rep3 record `git_dirty: true`. A dated correction was
   added to `PHASE_1_RESULTS.md` and the packet README. No measured value changed.
2. Local `refs/codex/turn-diffs/*` refs reach a `diff.txt` blob. It is not secret (the only pattern
   match is a false positive, `version_token`), but **push only `publication/readiness`, never
   `--all` or `--mirror`.**
3. `checkpoint.py` computes `log_path.relative_to(ROOT)`, which fails for an `--out` outside the
   repository. This is pre-existing and was left unchanged.
4. `run_phase1.py campaign` exits 0 even when every row is blocked. This is pre-existing and was
   left unchanged; the blocked status is recorded in its summary.
5. The dated planning records in `docs/publication/` and the review contain the author's home-path
   strings. They were left as records; the owner may redact them.

Publication blockers (owner actions):
- Confirm the copyright line, then push `publication/readiness`, open a PR to `main` and merge.
- Let CI run on GitHub. Inspect both jobs. The Linux install from the macOS-named lock and the
  `macos-26` fixture-byte check have not been executed remotely.
- Choose a security reporting route (or keep "pending" consciously).
- Human alignment listening check (only needed for validated-accuracy claims).
- After the merge: check GitHub rendering (SVG diagram in both themes, callouts, collapsible sections, links), the repository description/topics and
  branch protection, and open the URL in an incognito window.
- Supply the LinkedIn caption for review. Status: **NOT REVIEWED**.

## 13. PR title, body and integration plan

The code and documentation that were verified are at commit `5cd3f18bb0f3a24cedfad542cd0ee1e79e57b57f`.
The later commits on the branch add only this report, the updated checklist and a `.gitattributes`.
The `.gitattributes` keeps the evidence packet and the patch byte-exact (no EOL normalization) and
exempts their intentional CRLF and context whitespace from `git diff --check`.

**Title:** `Publish the benchmark harness: accurate scope, tested quick start, safe scripts, provenance, CI`

**Body** (ready to paste):

````markdown
## Summary

Brings the full benchmark harness to `main` (until now `main` held only the initial README) and makes it publishable:

- **Scope:** the README describes what exists: a Swift/Python benchmark harness with mock adapters by default and optional FluidAudio / speech-swift wrappers. The integrated voice engine is described as planned.
- **Onboarding:** `scripts/setup.sh` (Python 3.12 check, hash-locked venv, doctor, default build) and `scripts/smoke.sh` (one mock run → validate → export, with accounting assertions). Both are tested in a fresh clone.
- **Safety:** scripts refuse existing output instead of `rm -rf`. The default `Package.resolved` now matches the default graph, so builds no longer dirty the tree. Ignore rules are narrow.
- **Provenance:** a curated, owner-approved evidence packet for campaign 20261021-s2 (aggregates, identities, per-run record; no audio, transcripts or traces), `verify-speech` for the vendored SDK, and a dated correction (two runs recorded a dirty tree).
- **Tests:** a deterministic cancellation gate replaces a 200 ms wall-clock bound that failed under parallel load. The build-facts test knows each graph's floor.
- **Rights:** MIT for project files, and `THIRD_PARTY_NOTICES.md` for dependencies, models and AMI.
- **CI:** a Linux portable Python subset and a macOS mock-harness job. No models, data or secrets.

Includes the Phase 1 follow-up Step 0 work (native EOU stub tests, read-only audits, corrected results) and the publication planning records.

## Verification (local, Apple M5, macOS 26.6.2, Swift 6.3.2 CLT, Python 3.12.14)

See `docs/publication/REPO_PUBLICATION_VERIFICATION_REPORT.md`. It covers: a fresh clone following the README, the Swift and Python suites, doctor, the schema corpus (133 docs), fixture bytes (55, 0 mismatches), release e2e, an optional both-graph build plus stub tests, and the evidence recomputation.

## Not verified / out of scope

- No real-model inference was run (mock and stub tests only). There is no throughput, latency-to-word, ANE or power data, and no accuracy headline (accuracy stays conditional).
- CI has not run yet. GitHub rendering of the SVG diagram and callouts is unchecked. The security reporting route is pending.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
````

**Integration plan (each step requires explicit owner authorization):**

1. Owner reviews `git diff main...publication/readiness` (431 files vs `main`, 65 vs `e29f345`) and
   this report. Owner confirms the copyright line and decides on the security route.
2. `git push origin publication/readiness`. Push only this branch: no `--all`, no `--mirror`, so
   the local `refs/codex/*` are never pushed.
3. Open the PR against `main`, wait for `python-portable` and `macos-mock`, and fix any portability
   finding without rewriting goldens.
4. Merge. `main` is an ancestor, so fast-forward or a merge commit both work. No force-push.
5. On public `main`: check the rendered README, the diagram in light and dark mode, the links, and the license
   display. Apply the description and topics in [GITHUB_PRESENTATION.md](GITHUB_PRESENTATION.md) if
   wanted. Review branch protection. Open the URL in an incognito window.
6. Review the LinkedIn caption against README and the evidence packet before posting.

The original `imp/phase-1` checkout still holds the same owner changes, uncommitted. After the
merge, the owner can delete the worktree with `git worktree remove` (it is not deleted
automatically) and decide what to do with `imp/phase-1` and `diff.txt`.


## 14. Repository state and authorization used

- **Committed:** yes, locally on `publication/readiness` only (authorized by the implementation
  prompt). **Pushed:** no. **PR created:** no. **Merged:** no. **Tags/releases:** none.
  **GitHub settings/metadata:** unchanged.
- No model was downloaded and no license was accepted. No restricted asset was redistributed beyond
  the owner-approved aggregate packet. No long campaign was run. Network use: PyPI and SwiftPM
  package fetches, one shallow GitHub fetch of speech-swift `3f58a58a`, GitHub docs and release
  pages, and PyPI metadata for the Linux dry-run.
