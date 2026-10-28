# Security

## Reporting a vulnerability

**A private reporting route has not been selected yet** (pending owner decision). Until one is
listed here, please do **not** put exploit details, credentials or private data in a public issue.
Instead, open a public issue that only asks for a private contact and does not describe the problem.

## Threat model and trusted-run assumptions

This is a local benchmarking tool, not a service. It is designed to run on your own machine,
with inputs you created or reviewed.

- **Run directories are trusted input.** `voicebench validate --run`, `compare` and `export` execute
  the analysis interpreter whose absolute path is recorded in the run's `config.json`. Do not run
  them on run directories from someone else. To inspect copied evidence, use the current checkout's
  Python module with an explicit `--schemas` and an output outside the run ([docs/cli.md](docs/cli.md#trusted-runs-only)).
- **Configs, manifests and WAV files** are parsed strictly and validated, but treat them as code
  you choose to run. Strict parsing is not a sandbox.
- **Real-model runs** load only local model files whose hashes are listed in a profile. The Phase 1
  campaign wraps them in a deny-network `sandbox-exec` profile. That is a measurement control, not
  a security boundary for untrusted models.
- **Setup** downloads Python wheels with pinned SHA-256 hashes and SwiftPM packages at pinned
  versions from GitHub. It never uses sudo and never downloads models.

## Privacy

Run artifacts record absolute local paths, hardware and OS facts, and, for real data, transcript
text. Review a run directory before sharing any of it. The public Phase 1 evidence packet
(`docs/phase1/evidence/`) is a redacted, aggregate-only subset.
