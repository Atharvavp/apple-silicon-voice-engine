# Shared schema corpus

Used by both languages (plan D6, V13):

- `valid/<target>/` must pass JSON Schema validation (Python) and, for targets
  the Swift reader implements, strict Swift read + semantic validation, and
  must survive a Swift re-encode that Python validates again.
- `invalid/<target>/` must be rejected by JSON Schema or by the strict loader
  (duplicate keys, NaN/Infinity, lone surrogates, int64 overflow), and by Swift.
- `semantic-invalid/<target>/` are schema-valid on purpose: their defects are
  cross-field rules (interval order, coverage, speed reduction, frame
  integrality, ...) that the Swift reader rejects. Python semantic validators
  for persisted run artifacts arrive with `validate.py` in M4.

Digest values in this corpus are **placeholders for shape tests only**; they
are not content hashes of any file. `<target>` names map to schema URIs in
`analysis/src/phase0_analysis/schemas.py` (`TARGETS`).
