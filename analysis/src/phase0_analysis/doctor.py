"""Environment doctor: verifies the analysis environment without running models or reading audio.

Checks: interpreter version, required distributions and versions, importability
of the scorer classes (import only, no scoring), absence of model/inference
packages from the installed graph, schema store validity with offline ``$ref``
resolution, lock-file hashes, and a license inventory of every installed
distribution as declared in its own metadata.
"""

from __future__ import annotations

import hashlib
import importlib
import importlib.metadata as metadata
import platform
import re
import sys
from pathlib import Path
from typing import Any, Iterable

from . import __version__
from .schemas import SchemaStore

REQUIRED_PYTHON = (3, 12)

#: Distributions that must be installed, with the exact version where the plan pins one.
REQUIRED = {
    "jiwer": "4.0.0",
    "pyannote.metrics": "4.2.0",
    "pyannote.core": None,
    "jsonschema": None,
    "matplotlib": None,
    "numpy": None,
    "scipy": None,
}

#: Model/inference/network-fetching stacks that Phase 0 must never pull in.
FORBIDDEN = {
    "torch", "torchaudio", "torchvision", "pyannote.audio", "transformers", "tensorflow", "tensorflow-macos",
    "onnxruntime", "speechbrain", "lightning", "pytorch-lightning", "huggingface-hub", "nemo-toolkit",
    "openai-whisper", "faster-whisper", "ctranslate2", "coremltools", "mlx",
}

#: Symbols imported (never invoked) to prove the scorer API surface exists.
IMPORT_CHECKS = [
    ("jiwer", "process_words"),
    ("jiwer", "process_characters"),
    ("pyannote.core", "Annotation"),
    ("pyannote.core", "Segment"),
    ("pyannote.core", "Timeline"),
    ("pyannote.metrics.diarization", "DiarizationErrorRate"),
    ("pyannote.metrics.diarization", "JaccardErrorRate"),
    ("jsonschema", "Draft202012Validator"),
    ("matplotlib", "use"),
]


def _normalize(name: str) -> str:
    """PEP 503 name normalization."""
    return re.sub(r"[-_.]+", "-", name).lower()


def _license_of(dist: metadata.Distribution) -> str:
    meta = dist.metadata
    expression = meta.get("License-Expression")
    if expression:
        return expression.strip()
    declared = (meta.get("License") or "").strip()
    classifiers = [c.split("::")[-1].strip() for c in meta.get_all("Classifier") or [] if c.startswith("License ::")]
    if declared and len(declared) <= 80 and "\n" not in declared:
        return declared
    if classifiers:
        return "; ".join(classifiers)
    if declared:
        return declared.splitlines()[0][:80] + " (truncated license text)"
    for license_file in meta.get_all("License-File") or []:
        for candidate in (f"licenses/{license_file}", license_file):
            text = dist.read_text(candidate)
            if text and text.strip():
                return f"license file: {text.strip().splitlines()[0][:80]}"
    return "UNDECLARED"


def installed_distributions() -> list[dict[str, str]]:
    seen: dict[str, dict[str, str]] = {}
    for dist in metadata.distributions():
        name = dist.metadata.get("Name")
        if not name:
            continue
        seen[_normalize(name)] = {"name": name, "version": dist.version, "license": _license_of(dist)}
    return [seen[key] for key in sorted(seen)]


def forbidden_present(names: Iterable[str]) -> list[str]:
    forbidden = {_normalize(n) for n in FORBIDDEN}
    return sorted(n for n in names if _normalize(n) in forbidden)


def _sha256(path: Path) -> str | None:
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def env_info() -> dict[str, Any]:
    """Interpreter facts recorded in a run's environment.json (no imports of scorers, no network)."""
    import unicodedata

    return {
        "executable": sys.executable,
        "version": platform.python_version(),
        "analysis_version": __version__,
        "unicode_version": unicodedata.unidata_version,
        "distributions": {d["name"]: d["version"] for d in installed_distributions()},
    }


def run(schemas: Path, project_root: Path) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def record(check_id: str, ok: bool, detail: Any) -> None:
        checks.append({"check_id": check_id, "status": "pass" if ok else "fail", "detail": detail})

    version = sys.version_info
    record("python_version", (version.major, version.minor) == REQUIRED_PYTHON,
           {"required": ".".join(map(str, REQUIRED_PYTHON)), "found": platform.python_version()})

    dists = installed_distributions()
    by_name = {_normalize(d["name"]): d for d in dists}
    for name, pinned in REQUIRED.items():
        found = by_name.get(_normalize(name))
        ok = found is not None and (pinned is None or found["version"] == pinned)
        record(f"distribution:{name}", ok, {"pinned": pinned, "found": found["version"] if found else None})

    for module, symbol in IMPORT_CHECKS:
        try:
            loaded = importlib.import_module(module)
            ok = hasattr(loaded, symbol)
            detail = {"module_file": getattr(loaded, "__file__", None), "symbol": symbol}
        except Exception as exc:  # report, do not crash the doctor
            ok, detail = False, {"error": f"{type(exc).__name__}: {exc}"}
        record(f"import:{module}.{symbol}", ok, detail)

    present = forbidden_present(d["name"] for d in dists)
    record("no_model_or_inference_packages", not present, {"forbidden_found": present})

    try:
        store = SchemaStore(schemas)
        unresolved = store.check_offline_refs()
        record("schemas_valid_and_offline", not unresolved,
               {"schema_count": len(store.schemas), "unresolved_refs": unresolved})
    except Exception as exc:
        record("schemas_valid_and_offline", False, {"error": f"{type(exc).__name__}: {exc}"})

    analysis = project_root / "analysis"
    locks = {name: _sha256(analysis / name) for name in (
        "requirements-macos-arm64-py312.lock", "requirements-dev-macos-arm64-py312.lock",
        "requirements-bootstrap.txt")}
    record("lock_files_present", all(locks.values()), locks)

    return {
        "schema_version": "1.0",
        "tool": "phase0_analysis.doctor",
        "analysis_version": __version__,
        "python": {"executable": sys.executable, "version": platform.python_version(),
                   "implementation": platform.python_implementation()},
        "platform": {"system": platform.system(), "release": platform.release(), "machine": platform.machine()},
        "status": "pass" if all(c["status"] == "pass" for c in checks) else "fail",
        "checks": checks,
        "distributions": dists,
    }
