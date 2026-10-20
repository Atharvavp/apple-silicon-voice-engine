"""Strict JSON loading and local-only JSON Schema validation (plan D6).

JSON Schema (Draft 2020-12) is authoritative for persisted structure. Loading
is stricter than the stdlib defaults: duplicate keys, NaN/Infinity, invalid
UTF-8 and lone surrogates are rejected, and the ``integer`` type means a Python
``int`` (``1.0`` is *not* an integer) to match the Swift reader.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import referencing
import referencing.exceptions
from jsonschema import Draft202012Validator
from jsonschema.validators import extend
from referencing.jsonschema import DRAFT202012

SCHEMA_BASE = "https://schemas.voicebench.invalid/v1/"
SCHEMA_VERSION = "1.0"

#: Validation targets: corpus directory name -> schema URI (relative to SCHEMA_BASE).
TARGETS: dict[str, str] = {
    "config": "config.schema.json",
    "config-authored": "config.schema.json#/$defs/authored",
    "config-settings": "config.schema.json#/$defs/settings",
    "dataset": "dataset.schema.json",
    "annotations": "annotations.schema.json",
    "event": "event.schema.json",
    "metric-record": "common.schema.json#/$defs/metric_record",
    "predictions": "predictions.schema.json",
    "metrics": "metrics.schema.json",
    "telemetry": "telemetry.schema.json",
    "environment": "environment.schema.json",
    "runtime-summary": "runtime-summary.schema.json",
    "runtime-summary-conversion": "runtime-summary.schema.json#/properties/conversion",
    "status": "status.schema.json",
    "validation": "validation.schema.json",
    "comparison": "comparison.schema.json",
    "fixture-script": "fixture-script.schema.json",
}

#: Corpus targets that the Swift reader also implements (target -> `voicebench dev roundtrip --kind`).
SWIFT_KINDS: dict[str, str] = {
    "config-authored": "config",
    "dataset": "dataset",
    "annotations": "annotations",
    "event": "event",
    "metric-record": "metric",
    "status": "status",
    "fixture-script": "fixture-script",
}


class StrictJSONError(ValueError):
    """Raised when bytes are not acceptable Phase 0 JSON."""


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise StrictJSONError(f"duplicate object key {key!r}")
        result[key] = value
    return result


def _reject_constant(name: str) -> Any:
    raise StrictJSONError(f"non-finite number {name} is not allowed")


def _parse_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise StrictJSONError(f"number {text} is not a finite double")
    return value


def _check_strings(value: Any) -> None:
    """Rejects lone surrogates produced by ``\\udXXX`` escapes (not valid Unicode scalars)."""
    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, str):
            try:
                item.encode("utf-8")
            except UnicodeEncodeError as exc:
                raise StrictJSONError("string contains a lone surrogate") from exc
        elif isinstance(item, dict):
            stack.extend(item.keys())
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)


def loads_strict(data: bytes | str) -> Any:
    """Parses one JSON document with Phase 0 strictness rules."""
    if isinstance(data, bytes):
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise StrictJSONError("document is not valid UTF-8") from exc
    else:
        text = data
    try:
        value = json.loads(text, object_pairs_hook=_reject_duplicates, parse_constant=_reject_constant,
                           parse_float=_parse_float)
    except json.JSONDecodeError as exc:
        raise StrictJSONError(str(exc)) from exc
    _check_strings(value)
    return value


def load_strict(path: Path) -> Any:
    return loads_strict(Path(path).read_bytes())


def canonical_bytes(value: Any) -> bytes:
    """``settings_json_v1`` encoding; must equal the Swift ``JSONWriter.canonical`` bytes."""
    _forbid_floats(value)
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _forbid_floats(value: Any) -> None:
    if isinstance(value, float):
        raise StrictJSONError("settings_json_v1 permits integers only")
    if isinstance(value, dict):
        for item in value.values():
            _forbid_floats(item)
    elif isinstance(value, list):
        for item in value:
            _forbid_floats(item)


def _is_integer(_checker: Any, instance: Any) -> bool:
    return isinstance(instance, int) and not isinstance(instance, bool)


StrictValidator = extend(
    Draft202012Validator,
    type_checker=Draft202012Validator.TYPE_CHECKER.redefine("integer", _is_integer),
)


@dataclass(frozen=True)
class SchemaIssue:
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}: {self.message}"


def _json_path(parts: Any) -> str:
    out = "$"
    for part in parts:
        out += f"[{part}]" if isinstance(part, int) else f".{part}"
    return out


class SchemaStore:
    """All v1 schemas loaded from disk into an offline ``referencing`` registry.

    No retrieval callback is installed, so any ``$ref`` outside the bundled
    files raises ``Unresolvable`` instead of touching the network.
    """

    def __init__(self, root: Path):
        self.root = Path(root)
        resources = []
        self.schemas: dict[str, dict[str, Any]] = {}
        for path in sorted(self.root.glob("*.schema.json")):
            schema = load_strict(path)
            Draft202012Validator.check_schema(schema)
            expected_id = SCHEMA_BASE + path.name
            if schema.get("$id") != expected_id:
                raise ValueError(f"{path.name}: $id must be {expected_id}")
            self.schemas[path.name] = schema
            resources.append((expected_id, DRAFT202012.create_resource(schema)))
        if not self.schemas:
            raise ValueError(f"no *.schema.json files under {self.root}")
        self.registry: referencing.Registry = referencing.Registry().with_resources(resources)

    def validator(self, target: str) -> Any:
        if target not in TARGETS:
            raise KeyError(f"unknown validation target {target!r}")
        wrapper = {"$schema": "https://json-schema.org/draft/2020-12/schema", "$ref": SCHEMA_BASE + TARGETS[target]}
        return StrictValidator(wrapper, registry=self.registry)

    def issues(self, target: str, instance: Any) -> list[SchemaIssue]:
        errors = sorted(self.validator(target).iter_errors(instance), key=lambda e: list(e.absolute_path))
        return [SchemaIssue(_json_path(e.absolute_path), e.message) for e in errors]

    def check_offline_refs(self) -> list[str]:
        """Resolves every ``$ref`` in every schema; returns unresolved references."""
        problems = []
        for name, schema in self.schemas.items():
            resolver = self.registry.resolver(base_uri=SCHEMA_BASE + name)
            for reference in _iter_refs(schema):
                try:
                    resolver.lookup(reference)
                except referencing.exceptions.Unresolvable as exc:
                    problems.append(f"{name}: {reference}: {exc}")
        return problems


def _iter_refs(node: Any):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                yield value
            else:
                yield from _iter_refs(value)
    elif isinstance(node, list):
        for item in node:
            yield from _iter_refs(item)


def check_corpus(store: SchemaStore, fixtures: Path) -> dict[str, Any]:
    """Runs the shared corpus: ``valid/`` must pass, ``invalid/`` must fail.

    ``semantic-invalid/`` documents are schema-valid by design (their defects
    are cross-field rules enforced by the Swift reader); they must pass here.
    """
    fixtures = Path(fixtures)
    results = []
    for group, expect_valid in (("valid", True), ("invalid", False), ("semantic-invalid", True)):
        for target_dir in sorted((fixtures / group).glob("*")):
            if not target_dir.is_dir():
                continue
            target = target_dir.name
            for path in sorted(target_dir.glob("*.json")):
                try:
                    issues = [str(i) for i in store.issues(target, load_strict(path))]
                except StrictJSONError as exc:
                    issues = [f"$: load error: {exc}"]
                accepted = not issues
                results.append({
                    "file": str(path.relative_to(fixtures)), "target": target, "expected_valid": expect_valid,
                    "accepted": accepted, "ok": accepted == expect_valid, "issues": issues[:5],
                })
    covered = sorted({r["target"] for r in results if r["expected_valid"] and r["file"].startswith("valid/")})
    missing = sorted(set(TARGETS) - set(covered))
    return {
        "total": len(results),
        "failures": [r for r in results if not r["ok"]],
        "targets_without_valid_example": missing,
        "results": results,
    }
