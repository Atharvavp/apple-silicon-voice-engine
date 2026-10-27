# Dependency and license inventory

Python inventory generated on 2026-10-20 from the installed, hash-locked
environment with `phase0_analysis.doctor.installed_distributions()`. Licenses
are copied from each package's own metadata or bundled license file, not
inferred. The project is MIT-licensed ([LICENSE](../LICENSE)); what that does
and does not cover, the optional SDK graph and the model/data terms are in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Before redistributing a
binary, preserve third-party notices, including the upstream libyaml notice.

## Lock policy

| Lock | Graph | SHA-256 |
|---|---|---|
| `Package.resolved` (committed root) | default `PHASE1_FRAMEWORKS=none`: 2 pins | `618f25a5836f7d4e196e70b9d73de41c3f3e62c6e39eab8c4e38347cd53f590c` |
| `docs/phase1/evidence/20261021-s2/Package.resolved.both` | historical `both` graph of campaign 20261021-s2: 41 pins | `aee60879806d3b495c2794a43743114016a2803e8053d97fc350fc83644c2a3f` |

Default builds leave the committed lock unchanged. Optional builds
(`fluid`, `speech`, `both`) rewrite `Package.resolved` for their graph; build
them in a separate checkout (see [development.md](development.md)), starting
from the historical `both` lock to keep its transitive pins, and do not commit
the result. `vendor/speech-swift` is a path dependency that no lock can pin;
authenticate it with `scripts/run_phase1.py verify-speech`. Python locks are
regenerated only deliberately with pip-tools 7.6.2; `setup.sh` never
regenerates them.

## Swift default graph (Package.resolved)

(The 2026-10-20 edition recorded root lock SHA-256
`3da9b6ce9c6b1f4665eb85e7d0f220863f97f2b9541ad801f4b54a8647dd8afa` with the
same two pins.)

| Package | Pin | Revision | License (checkout file) |
|---|---|---|---|
| swift-argument-parser | exact 1.8.2 | 6a52f3251125d74daf04fcbd5e6f08a75d074382 | Apache-2.0 with the Swift Runtime Library Exception (`LICENSE.txt`) |
| Yams | exact 6.2.2 | a27b21e0c81c5bf42049b897a62aaf387e80f279 | MIT (`LICENSE`, JP Simard). Vendors libyaml in `Sources/CYaml`; its README says libyaml is MIT, but no separate libyaml notice ships in the checkout |
| Apple frameworks (AVFAudio, Foundation, CryptoKit, Darwin, os) | SDK MacOSX26.5 | — | Apple SDK terms (system frameworks, not redistributed) |

## Python 3.12.14 (macOS arm64)

| Lock | SHA-256 |
|---|---|
| `analysis/requirements-macos-arm64-py312.lock` (runtime) | `75301ec0e76fd572f5d396924283c1cab2e73ffccf9f3894e7b17b01a0e225f5` |
| `analysis/requirements-dev-macos-arm64-py312.lock` (runtime + pytest + pip-tools) | `bfaeff972c43f6ec9a9c85d2015108ecfadcfc5ff44943aa404c0d8d1c16ddbe` |
| `analysis/requirements-bootstrap.txt` (pip-tools 7.6.2, BSD-3-Clause) | `0a8777439f9ab40dd5cea5935faa0c8ae9d7d3b7a342452babcc9f2895c75ea5` |

Install: `.venv/bin/python -m pip install --require-hashes -r analysis/requirements-dev-macos-arm64-py312.lock`.
`pip check` reports no broken requirements. The doctor confirms that no model,
inference or hub-download package (torch, pyannote.audio, transformers,
onnxruntime, huggingface-hub, …) is installed.

| Distribution | Version | License (as declared) | Kind |
|---|---|---|---|
| attrs | 26.1.0 | MIT | transitive |
| build | 1.6.1 | MIT | transitive |
| click | 8.5.0 | BSD-3-Clause | transitive |
| cloudpickle | 3.1.2 | BSD-3-Clause | transitive |
| contourpy | 1.4.0 | BSD-3-Clause | transitive |
| cycler | 0.12.1 | BSD License | transitive |
| fonttools | 4.67.0 | MIT | transitive |
| iniconfig | 2.3.1 | MIT | transitive |
| jiwer | 4.0.0 | Apache-2.0 | direct |
| joblib | 1.6.0 | BSD-3-Clause | transitive |
| jsonschema | 4.26.0 | MIT | direct |
| jsonschema-specifications | 2025.9.1 | MIT | transitive |
| kiwisolver | 1.5.1 | BSD License | transitive |
| matplotlib | 3.11.2 | Python Software Foundation License | direct |
| narwhals | 2.27.1 | MIT | transitive |
| numpy | 2.5.4 | BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0 | transitive |
| packaging | 26.3 | Apache-2.0 OR BSD-2-Clause | transitive |
| pandas | 3.0.6 | BSD License | transitive |
| pillow | 13.0.0 | MIT-CMU | transitive |
| pip | 26.2.1 | MIT | transitive |
| pip-tools | 7.6.2 | BSD-3-Clause | direct |
| pluggy | 1.7.0 | MIT | transitive |
| pyannote-core | 6.1.0 | license file: The MIT License (MIT) | transitive |
| pyannote-database | 6.1.1 | license file: The MIT License (MIT) | transitive |
| pyannote-metrics | 4.2.0 | license file: The MIT License (MIT) | direct |
| Pygments | 2.21.0 | BSD-2-Clause | transitive |
| pyparsing | 3.3.3 | MIT | transitive |
| pyproject_hooks | 1.3.3 | MIT | transitive |
| pytest | 9.1.1 | MIT | direct |
| python-dateutil | 2.9.0.post0 | Dual License | transitive |
| PyYAML | 6.0.3 | MIT | transitive |
| RapidFuzz | 3.14.6 | MIT | transitive |
| referencing | 0.37.0 | MIT | transitive |
| rpds-py | 2026.9.1 | MIT | transitive |
| scikit-learn | 1.9.1 | BSD-3-Clause | transitive |
| scipy | 1.18.1 | BSD License | transitive |
| setuptools | 84.0.0 | MIT | transitive |
| six | 1.17.0 | MIT | transitive |
| sortedcontainers | 2.4.0 | Apache 2.0 | transitive |
| threadpoolctl | 3.7.0 | BSD-3-Clause | transitive |
| typing_extensions | 4.16.0 | PSF-2.0 | transitive |
| wheel | 0.48.0 | MIT | transitive |

Provenance, from the lock's `# via` comments: pyannote.metrics 4.2.0 itself
requires pyannote-core, pyannote-database (which brings PyYAML), pandas,
scikit-learn and scipy. jiwer brings click and RapidFuzz. None of these is a
model package.
`pip`, `setuptools`, `wheel`, `build` and `pyproject_hooks` are packaging
tools pulled in by pip-tools and the venv.
