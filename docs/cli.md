# `voicebench` CLI (Phase 0)

One experiment (one dataset item, one stream) per process. Phase 0 ships mock
adapters only: scores validate the harness, never speech recognition.

```text
voicebench run --config FILE --runs-dir DIR [--run-id ID]
    [--mode realtime|accelerated|step] [--frame-ms 10|20|40|80] [--speed DECIMAL]
    [--queue-capacity N] [--overflow block|drop_newest] [--seed N] [--python-executable ABS_PATH]
voicebench validate --run DIR [--rescore [--analysis-id ID]] [--require-exact-endpoints]
voicebench validate --dataset FILE [--require-ready]
voicebench validate --suite gate-a --evidence-dir DIR
voicebench compare --runs DIR DIR [DIR ...] --profile accuracy|latency|resources [--allow-noncomparable] --out DIR
voicebench export --run DIR --out DIR [--format csv|plots|all]
voicebench --help | --version
```

## Behavior

- **Overrides** are applied after strict YAML loading and before semantic validation,
  so a flag can never bypass a check; the result is frozen in `config.json`.
  `--speed` is accepted only with an effective accelerated mode.
- **Outputs are never overwritten.** Run IDs must be new; `compare`/`export` need a
  new or empty `--out`; analyses of an existing run go only into its `derived/`.
- **`validate --run`** re-checks a sealed run (schemas, every sealed digest, the
  runtime prefix, prediction rebuild, coverage, telemetry, metrics inputs, schema
  bundle) and writes `derived/validation-<id>/validation.json`. Endpoint corrections
  and data loss are printed as disclosures; `--require-exact-endpoints` (or a run
  made with `endpoint_policy: strict`) turns a correction into a failure.
- **`validate --rescore`** recomputes metrics into `derived/<analysis-id>/`; the
  initial `metrics.json` is untouched.
- **`validate --dataset`** checks structure, and for ready items the files, hashes and
  reference documents. A pending manifest is valid but fails `--require-ready`.
- **`compare`** reports field-level reasons (`blocks_ranking` or `disclosed`). It ranks
  only compatible runs whose primary metric is `ok`. Failed, unsealed or invalid runs,
  lossy runs (accuracy), step-mode latency and unverified hardware block ranking.
  `--allow-noncomparable` emits labelled side-by-side rows, never a ranking.
- **`export`** writes `metrics.csv`, `predictions.csv`, `timing.csv`, `resources.csv`,
  `loss-ranges.csv` and three PNG plots. Missing values are blank with their status
  and reason; plots carry run ID, units, sample count and the MOCK label.
- The analysis interpreter and project root come from the run's frozen
  `config.json`, never from the ambient `python3`.

## Exit codes (plan G3)

| Code | Meaning |
|---:|---|
| 0 | success (or labelled non-comparable output with `--allow-noncomparable`) |
| 2 | invalid CLI input, config, or an output that already exists |
| 3 | dataset: manifest, hashes, pending dataset, missing required references |
| 4 | audio: unsupported/corrupt WAV, conversion contract (e.g. strict endpoint policy) |
| 5 | runtime: adapter failure, contract violation, coverage/integrity failure |
| 6 | recorder: disk, permission, output ceiling, finalization |
| 7 | analysis: Python helper, import, scoring error or timeout |
| 8 | comparison incompatible |
| 9 | validation failed (run, dataset `--require-ready`, acceptance suite) |
| 130 | interrupted (SIGINT/SIGTERM); the run ends `cancelled` |
