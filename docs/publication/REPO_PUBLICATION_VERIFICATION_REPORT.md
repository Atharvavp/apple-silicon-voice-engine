# Repository publication verification report

Prepared 2026-10-27 (Asia/Kolkata) for the owner. It records the implementation of
[REPO_PUBLICATION_PLAN.md](REPO_PUBLICATION_PLAN.md) on a local candidate branch.

**State (2026-10-28): PR OPEN, CI GREEN ON `2f482e0`, AWAITING THE OWNER'S MERGE DECISION.** The branch
`publication/readiness` is pushed and [PR #1](https://github.com/Atharvavp/apple-silicon-voice-engine/pull/1)
targets `main`. It is not merged, and public `main` is still the two-line initial README. Sections
1–14 record the 2026-10-27 local implementation. Commit IDs cited there are pre-rewrite IDs with
identical trees; see §15 for the mapping.

## 1. Baseline and candidate identities

| | Value |
|---|---|
| Original checkout | the owner's development checkout (local path not published), branch `imp/phase-1`, HEAD `e29f345abbdaa68cd496955b5e00f3fed86b140d`, dirty (4 modified, 9 untracked paths) |
| `main` / `origin/main` | `4a5d3abf5f5c42dfb873737b89ebbe58237b5a60` (initial commit, README only), an ancestor of the candidate, so a fast-forward is possible |
| Remote | `https://github.com/Atharvavp/apple-silicon-voice-engine.git` (no embedded credentials) |
| Candidate branch | `publication/readiness`, local only, in a separate local worktree next to the original checkout |
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

- **PR:** [#1](https://github.com/Atharvavp/apple-silicon-voice-engine/pull/1), "Publish the benchmark
  harness: accurate scope, tested quick start, safe scripts, provenance, CI", `publication/readiness`
  → `main`. The description lives on the PR. It has no AI-attribution footer, by owner instruction.
- **Integration plan (owner actions):**
  1. Review PR #1 and merge it. `main` is an ancestor, so a fast-forward or a merge commit both
     work. No force-push.
  2. After the merge, check the rendered README and diagram in light and dark mode, and the
     license detection.
  3. Apply the About-panel description and topics ([GITHUB_PRESENTATION.md](GITHUB_PRESENTATION.md)).
     The current live description still claims "a fully on-device, real-time voice intelligence
     engine" and contradicts the README.
  4. Decide whether to delete the remote `imp/phase-0` branch. It still holds the three pre-rewrite
     Phase 0 commits with the AI co-author trailer (§15).
  5. Review branch protection, open the repository in an incognito window, and review the LinkedIn
     caption.
- The original `imp/phase-1` checkout keeps the pre-rewrite commit IDs. Further work there would
  need a rebase onto the published history. The local worktree can be removed with
  `git worktree remove` once you no longer need it.

## 14. Repository state and authorization used

- **Committed and pushed:** `publication/readiness` only, by explicit refspec. No `--all`,
  `--mirror` or force-push was used. No other branch or tag was pushed. The local
  `refs/backup/publication-readiness-pre-attribution`, `refs/original/*` and `refs/codex/*` refs
  stay local.
- **PR created:** yes, #1 (authorized 2026-10-28). **Merged:** no. **Tags/releases:** none.
  **GitHub settings/metadata:** unchanged. `main` was not modified.
- No model was downloaded and no license was accepted. No restricted asset was redistributed beyond
  the owner-approved aggregate packet. No long campaign was run. The original development checkout
  was not modified (20/20 pre-existing files hash-identical, same HEAD and status).
- GitHub API calls (PR creation, CI inspection) used the git credential already stored for this
  remote. It was never printed or written to a file.

## 15. Publication stage (2026-10-28)

### Attribution audit

- **Inspected:** all 22 commits in `origin/main..publication/readiness` (author, committer, both
  emails, full messages and trailers), plus the public `origin/imp/phase-0` and `origin/main`
  commits, repository content, the PR template, the PR body and GitHub's own rendering of
  attribution.
- **Identities:** one author and one committer, `Atharvavp <atharva.vijay.pawar@gmail.com>`. GitHub
  resolves this email to the account `Atharvavp` (profile name Atharva Pawar), confirmed through the
  commit API and commit pages. The initial commit on `main` is `Atharva Pawar
  <70878243+Atharvavp@users.noreply.github.com>`, committed by GitHub's web UI.
- **AI attribution found:** every one of the 22 commits ended with `Co-Authored-By: Claude Opus 5.5
  <noreply@anthropic.com>`. That includes the six Phase 0/1 commits from earlier sessions, three of
  which were already public on `imp/phase-0`. It sat in commit-message trailers only, not in Git
  author or committer metadata. GitHub resolved it to the user account `claude` and listed that
  account as a co-author on the public commit pages, so after a merge it would have been credited
  on `main`. There was no `Signed-off-by` or other automated trailer.
- **Correction (owner-approved 2026-10-28):** a message-only rewrite of all 22 commits
  (`git filter-branch --msg-filter`, removing that exact trailer line). Verified per commit: tree,
  author name/email/date and committer name/email/date are identical, and the message is identical
  except for the removed line. Nothing was force-pushed, because the branch was new on the remote.
  Later commits were made without any trailer.
- **After the rewrite:** the PR's 25 commits all resolve to author and committer `Atharvavp`, with 0
  AI trailers. Anonymous commit pages list only `Atharvavp`. The repository contributors list
  (default branch) shows only `Atharvavp`.
- **Remaining risk:** the remote `imp/phase-0` branch still holds the three pre-rewrite commits
  (`a1835de`, `17ec563`, `b6143b6`), whose pages show `claude` as co-author. They are not on `main`
  and do not become part of it. Deleting that branch is the owner's decision.
- **Content (owner-approved trim):** the internal implementation prompt was removed from the
  published tree. Local paths and the tool-specific verifier line were neutralized. The review file
  `CODEX_INDEPENDENT_REVIEW.md` keeps its name as historical provenance. `doctor.py` lists
  `openai-whisper` only as a forbidden package name. The prompt file still exists in branch history
  (commit `69aae8f`); removing it there would need another rewrite and was not requested.

Commit ID mapping (trees identical):

| Before | Published |
|---|---|
| `a1835de` | `80a1f0e` |
| `17ec563` | `182ebea` |
| `b6143b6` | `53e597a` |
| `e27605b` | `eadbfaa` |
| `da04cd2` | `8fc46d0` |
| `e29f345` | `873e5df` |
| `dd3675c` | `71f37ab` |
| `a906ce8` | `69aae8f` |
| `9f92393` | `5b98644` |
| `c1c530e` | `efa18d2` |
| `19c6238` | `6b79eda` |
| `14e4267` | `3e345f6` |
| `929ab80` | `0c3abd2` |
| `85d5968` | `b80c408` |
| `2cc6bbf` | `9f2a159` |
| `0dff472` | `96ad089` |
| `877ecbb` | `acd6efa` |
| `af7108e` | `ed11001` |
| `5cd3f18` | `2f38aef` |
| `21045ba` | `7b9e634` |
| `9841f89` | `e49d54f` |
| `6ded9b4` | `c31f92b` |

The campaign's recorded source revision `e29f345` is published as `873e5df` (tree `d7b25936…`). This
is noted in the evidence packet README and in the corrections of `PHASE_1_RESULTS.md`. The sealed
values are unchanged.

### Public content audit

437 tracked files at `0d56cca`. No credentials (bounded pattern scan), no `.env`, keys, model files
or archives, no AMI audio or transcripts, no `diff.txt` or inputs file. The largest file is a 1.5 MB
synthetic tone fixture. All 52 WAVs are regenerated byte-identically by `generate_fixtures.py`. The
evidence packet holds aggregates only, and its manifest hashes verify. No email addresses appear
outside lock files. The remaining absolute paths are a parser fixture (`/Users/example/…`), the
exporter's own path guard, and dated audit records. LICENSE (MIT) and THIRD_PARTY_NOTICES are
unchanged and accurate.

### Local verification of the pushed candidates

| Commit | Checks | Result |
|---|---|---|
| `0d56cca` (first push) | Fresh clone, README order, full matrix | All exit 0. 212 Swift, 289 Python, e2e 45/45, fixtures 55/0, schema 133, doctor, smoke, 0 tracked changes |
| `e4e453d` | Swift suite through the fixed wrapper (CLT) | 212 passed. Publication-script tests 17 passed |
| `b94c80c` | Swift suite | 212 passed |

### Push, PR and CI

| Commit | Run | `python-portable` (ubuntu-24.04 x64, Python 3.12.15) | `macos-mock` (macos-26-arm64 M1, macOS 26.6.2, Xcode 26.6, Swift 6.3.3, Python 3.12.10) |
|---|---|---|---|
| `0d56cca` | 40566921491 | success: hash-locked install, `pip check`, 70 passed, schema 133 | **failure** in the Swift suite step: `scripts/swift_test.sh: line 19: flags[@]: unbound variable` |
| `e4e453d` | 40568881402 | success | **failure**: 211/212. `timeoutTerminatesTheChild` measured 10.93 s against a 10 s bound |
| `b94c80c` | [40590411586](https://github.com/Atharvavp/apple-silicon-voice-engine/actions/runs/40590411586) | **success** | **success**: doctor, 212 Swift, 289 Python, fixture bytes 55/0, schema 133, smoke, tracked files unchanged |
| `cb1fc31` (docs only) | [40591971932](https://github.com/Atharvavp/apple-silicon-voice-engine/actions/runs/40591971932) | success | **failure**: 211/212. The real-clock `cancellationStopsRealtimeReplayPromptly` measured 9.38 s against its 5 s gate; its `CancellationError` check and the deterministic cancellation test passed |
| `2f482e0` | [40592913631](https://github.com/Atharvavp/apple-silicon-voice-engine/actions/runs/40592913631) | **success**: 70 passed, schema 133 | **success**: doctor, 212 Swift, 289 Python, fixture bytes 55/0, schema 133, smoke, tracked files unchanged |

`2f482e0` is the last commit that changes code or tests. The commit that adds this table changes
only this report and the checklist; its CI result is on the PR's checks.

The two fixes were reproduced and explained before changing anything:

1. **Wrapper bug (genuine, pre-existing).** With Xcode selected, the CLT-only flag array is empty.
   macOS `/bin/bash` 3.2 treats an empty array as unbound under `set -u`, so the script exited
   before running any test (reproduced locally). The fix is the 3.2-safe expansion
   `${flags[@]+"${flags[@]}"}`. The Command Line Tools path is unchanged.
2. **Host-speed bounds in two tests.** On the 3-core runner, the sibling bridge tests whose child
   exits immediately also took about 11.9 s, which identifies cold Python launch as the cause, and
   `timedOut` was true. `timeoutTerminatesTheChild` now uses a 120 s child sleep with a 60 s bound
   and requires that the child ended by SIGTERM/SIGKILL. `stepDelayIsVirtualOnly` (15.0 s against
   its 15 s bound) now uses 25 s, which is still below the 30 s that sleeping the virtual delay
   takes. Both are test-only changes, with no production change and no skipped test.
3. **Flaky real-clock cancellation gate (the F08 pattern on a 3-core host).** The same test passed
   on `b94c80c` and failed on the docs-only `cb1fc31`. On 3 cores the cooperative pool took 9.4 s to
   resume the cancelled waiters, and a run that ignores cancellation until the stream ends would
   take only about 11.9 s, so no wall-clock gate separates the two reliably. The test now checks
   structure: it requires `CancellationError` and that fewer than all 600 chunks are delivered (a
   run honored only at the end delivers all 600). The latency and chunk count are recorded as
   evidence. The 5 s and 200 ms targets moved under the opt-in `VOICEBENCH_TIMING_CHECKS=1`. The
   deterministic propagation test remains the correctness gate. This is a test-only change.

The Linux install from the macOS-named hash lock, previously NOT VERIFIED, **passed** with
`--require-hashes` intact.

### GitHub rendering and access

- Verified anonymously (no authentication) from the PR branch's rendered README HTML:
  - both callouts render as GitHub alerts (`markdown-alert-note`, `-warning`);
  - the collapsible sections and the `<picture>` with its `prefers-color-scheme: dark` source are present;
  - every jump-link anchor exists.
- Both SVGs are served as `image/svg+xml`, byte-identical to the repository files.
- The LICENSE, evidence packet, provenance JSON and docs pages return HTTP 200. The PR page returns
  HTTP 200 anonymously.
- **NOT VERIFIED:**
  - a visual look at the rendered page in a browser, in light and dark themes (no browser was
    available to this session; only the markup and assets were checked);
  - GitHub's license detection, which reports none for a non-default branch and is expected after
    the merge;
  - an incognito check of the final `main` URL.

### Repository metadata review

The proposal in [GITHUB_PRESENTATION.md](GITHUB_PRESENTATION.md) is accurate: a 220-character
description of a benchmark harness, 12 valid topics, no homepage, no social preview. It should
replace the live description, which overclaims "a fully on-device, real-time voice intelligence
engine … VAD". The live repository has no topics, no homepage and no detected license. No setting
was changed.

### Remaining blockers and owner decisions

- Merge PR #1 (owner).
- After the merge: apply the description and topics, check rendering in both themes and the license
  detection, check incognito access, review branch protection.
- Decide whether to delete the remote `imp/phase-0` branch (pre-rewrite AI-trailer commits).
- Security reporting route (still pending) and the manual alignment listening check (accuracy stays
  conditional).
- LinkedIn caption: NOT REVIEWED (none supplied).
