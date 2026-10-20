# API verification ledger

Every platform or library behavior the code relies on, with how it was
verified. "Compiled" means it built under the toolchain below. "Exercised"
means a test called it and checked the result. Observed values come from test
or probe output, not documentation, unless marked "header".

**Toolchain:** Apple Swift 6.3.2 (swiftlang-6.3.2.1.108), Command Line Tools only
(`/Library/Developer/CommandLineTools`, no Xcode), SDK MacOSX26.5, macOS 26.6.2
(25G83), arm64. Hardware read via `sysctl`: `Mac17,3`, Apple M5, 17,179,869,184
bytes RAM. Package tools-version 6.0, Swift 6 language mode, deployment floor
`.macOS(.v13)`. Running on macOS 13 itself is **untested**.

## Swift / Apple SDK

| API | Used for | Verification | Observed / notes |
|---|---|---|---|
| `AVAudioFile(forReading:commonFormat:interleaved:)` with `.pcmFormatFloat32`, `false` | WAV decode | Compiled; exercised on 23 fixtures (`WAVDecoderTests`) | Decodes PCM s16/s24/s32, Float32, and WAVE_FORMAT_EXTENSIBLE PCM/Float GUIDs, mono and stereo, at 16, 22.05, 44.1 and 48 kHz. `length`, `fileFormat.channelCount` and `sampleRate` match the RIFF inspector for every fixture. |
| Integer → Float32 scaling by AVAudioFile | Decode | Exercised (`integerScalingWithinOneLSB`) | Matches `code / 2^(bits-1)` within max(1 LSB, Float ulp). The PCM32 max code 2147483647 decodes to 1.0 (Float rounding), and −2^(bits-1) decodes to −1.0. Evidence: `V01/scaling-*.json`. |
| Float32 WAV samples outside ±1 | Decode | Exercised | Preserved exactly (`[0, 1.5, -2, 0.125]`); no clipping. NaN/Inf are rejected by the harness (`nonFiniteSample`), not by the decoder. |
| `AVAudioPCMBuffer(pcmFormat:frameCapacity:)`, `frameLength`, `floatChannelData`, `stride` | Decode/convert buffers | Compiled; probe | `stride == 1` for deinterleaved mono. Samples are always copied out before reuse. |
| `AVAudioConverter(from:to:)` + `convert(to:error:withInputFrom:)` | SRC | Compiled; exercised on 8 resampled fixtures | The input block type is `NS_SWIFT_SENDABLE` (header line 154), which Swift imports as `@Sendable`. The header doesn't say which thread runs it, so the feed state is lock-protected. Header: the simple `convert(to:from:)` overload "does not involve … sample rate conversion". |
| `sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal`, `sampleRateConverterQuality = AVAudioQuality.max.rawValue`, `primeMethod = .normal` | SRC policy `apple_normal_max_half_up_v1` | Exercised | `primeInfo` = leading 0, trailing 0. Native output count equals `floor((Nin·Rout + floor(Rin/2))/Rin)` for the 8 original fixtures, but **not in general**. Hardening matrix: 46 of 243 (rate pair, length) cases differ by exactly ±1. Native counts round down on some ratios (11.025k→16k, 16k→44.1k, 96k→16k, 44.1k→16k for 7 and 10 frames) and up on 22.05k→16k. The difference is never more than one frame, and output is identical for input callbacks of 1, 7, 97, 1000 and 4096 frames on five ratios. Impulses at exact-mapping positions peak exactly there for 8 ratios, including upsampling. A last-sample impulse whose exact output position falls past the final frame keeps about half its amplitude (`M2-hardening/H3/*`). The 48 kHz impulse at index 24000 lands at 16 kHz index 8000 (peak 0.3). The 1 kHz RMS ratio is 0.9999996 at 48 kHz and 1.0000053 at 44.1 kHz. DC error is 1.19e-7. The 12 kHz tone is attenuated 125.9 dB. Output hash is identical for input callbacks of 4096, 1000 and 97 frames. Evidence: `V02/src-probes.json`, `V02/split-block.json`, `V02/conversions.json`. These results are SDK-specific and not a cross-SDK golden. |
| `ContinuousClock`: `now`, `Instant.duration(to:)`, `advanced(by:)`, `sleep(until:tolerance:)`, `minimumResolution` | Run clock | Exercised (`ClockTests`, replay tests) | `minimumResolution` = 4.2e-08 s (42 ns). Sleep never returned before its deadline (50/50 wake errors ≥ 0). Wake latency on this host: see decisions.md (P01 input). |
| `Duration.components` (seconds, attoseconds) | Integer ns conversion | Exercised | Truncation toward zero; overflow is detected by checked multiply/add. |
| `getrusage(RUSAGE_SELF, &rusage)` | CPU telemetry (M5) | Probe called from Swift | Returns 0. `ru_utime`/`ru_stime` are nonzero (user 12.1 ms, system 18.0 ms in the probe process). The M5 C shim is not built yet. |
| `task_info(mach_task_self_, TASK_VM_INFO, …)` | Current RSS (M5) | Probe called from Swift | `KERN_SUCCESS`; returned count 93, which covers `phys_footprint`. `resident_size` was 13,746,176 bytes. |
| `ProcessInfo.processInfo.thermalState` | Thermal (M5) | Probe | Raw value 0 (nominal). Per the header, nominal can also mean unsupported. |
| `OSAllocatedUnfairLock` (`initialState:`, `uncheckedState:`, `withLock`, `withLockUnchecked`) | FakeRunClock, converter feed | Compiled/exercised | Available on macOS 13+. |
| `FileHandle` seek/read/write/truncate/synchronize, `open(O_CREAT\|O_EXCL)` | Spool I/O | Exercised | `FileManager.createFile` overwrites existing files, so exclusive creation uses `open` with `O_EXCL` (`spoolNeverOverwritesExistingFile`). |
| `CryptoKit.SHA256` (incremental) | File and settings hashes | Exercised | Streamed in 1 MiB blocks; Python `hashlib` parity on settings bytes is tested. |
| Thread Sanitizer (`swift test --sanitize=thread` via `scripts/swift_test.sh`) | Concurrency hardening | Exercised (M2 hardening checkpoint) | Works with the Command Line Tools. The test bundle links `libclang_rt.tsan_osx_dynamic.dylib` (`otool -L`). 33 queue and replay tests produced 0 reports. |
| `UInt64.multipliedFullWidth`, `dividingFullWidth` | 128-bit exact sample/time math | Exercised | The quotient-overflow precondition is guarded (`high < divisor`) before dividing. |

## Swift packages

| Package | API relied on | Verification |
|---|---|---|
| swift-argument-parser **1.8.2** (rev `6a52f32…`) | `ParsableCommand`, `CommandConfiguration(version:, subcommands:, shouldDisplay:)`, `@Option` | Compiled; `--help` and `--version` run in the M1 checkpoint. The hidden `dev` subcommands are used by Python parity tests. |
| Yams **6.2.2** (rev `a27b21e…`) | `Parser(yaml:).singleRoot()` | Source: throws "expected a single document" on a second document. Tested. |
| | Duplicate keys | Source `Parser.checkDuplicates` throws `duplicatedKeysInMapping`. Key equality includes the **resolved tag**, so `"1": a` and `1: a` aren't duplicates to Yams; the harness's own by-string check rejects them. |
| | `Node.anchor`, alias handling | Source: `loadAlias` returns the anchored node itself, so aliases are invisible after composition. Rejecting every anchor makes aliases impossible. Tested. |
| | `Tag` | `Tag` is a class. `Node.Scalar` hashing calls `resolvedTag`, which **mutates `Tag.name` in place**, so key tags look resolved after the duplicate check. `Tag.name` is internal; `Tag.description` (public) returns it. Quoted scalars get the `str` tag (`quoted_implicit`). Tested via explicit `!!int "1"` and `!custom` cases. |

## Python (venv: Python 3.12.14, installed from `requirements-dev-macos-arm64-py312.lock` with `--require-hashes`)

| Package | API relied on | Verification |
|---|---|---|
| jsonschema 4.26.0 + referencing 0.37.0 | `Draft202012Validator.check_schema`, `validators.extend(type_checker=…redefine("integer", …))`, `referencing.Registry().with_resources`, `DRAFT202012.create_resource`, `Registry.resolver().lookup` raising `Unresolvable` | 95-document corpus. An offline lookup of an unbundled URI raises `Unresolvable` (tested). `enum` matches by numeric equality (`20.0 == 20`), which is why every numeric enum also states `"type": "integer"`. |
| `json.loads(object_pairs_hook=, parse_constant=, parse_float=)` | Strict loader | Duplicate keys, NaN/±Infinity, 1e400 and invalid UTF-8 are rejected. Lone-surrogate escapes are accepted by `json` and rejected by an explicit UTF-8 encode check. All tested. |
| jiwer 4.0.0 | `process_words`, `process_characters` | **Import only** (doctor). Count semantics are verified against goldens in M5. |
| pyannote.core 6.1.0 / pyannote.metrics 4.2.0 | `Annotation`, `Segment`, `Timeline`, `DiarizationErrorRate`, `JaccardErrorRate` | **Import only** (doctor). Signatures and components are verified in M5. Their package metadata declares no license; each wheel ships an MIT `LICENSE` file (read by the doctor). |
| matplotlib 3.11.2 | `use("Agg")` | Import only. |

## Not yet verified (owned by later milestones)

- C shim for `getrusage`/`task_info` (M5); runner-process sampler cadence.
- Installed jiwer transform and count fields; pyannote detailed components, mapping and empty cases (M5).
- Signal handling (SIGINT/SIGTERM dispatch source), child-process pipe draining and timeouts, atomic rename durability (M4).
- `/usr/bin/sandbox-exec` network denial (M7). The binary exists, but it hasn't been exercised.
- Behavior on macOS 13–25 or with Python other than 3.12.14.
