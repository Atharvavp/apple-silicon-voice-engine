"""``python -m phase0_analysis <operation>``; operations are added milestone by milestone."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def _write(report: dict, out: str | None, exclusive: bool = False) -> None:
    """Writes JSON; ``exclusive`` refuses to replace an existing file (run artifacts are immutable)."""
    text = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    if out:
        path = Path(out)
        path.parent.mkdir(parents=True, exist_ok=True)
        if exclusive:
            tmp = path.with_name(path.name + ".tmp")
            with open(tmp, "x", encoding="utf-8") as handle:
                handle.write(text)
                handle.flush()
                os.fsync(handle.fileno())
            os.link(tmp, path)  # fails if the destination exists
            os.unlink(tmp)
        else:
            path.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)


def _schemas(explicit: str | None) -> Path:
    """Schema root: explicit flag, then VOICEBENCH_SCHEMAS (set by the Swift bridge), then the repo copy."""
    if explicit:
        return Path(explicit)
    if os.environ.get("VOICEBENCH_SCHEMAS"):
        return Path(os.environ["VOICEBENCH_SCHEMAS"])
    return Path(__file__).resolve().parents[3] / "schemas/v1"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="phase0_analysis")
    sub = parser.add_subparsers(dest="operation", required=True)

    doctor = sub.add_parser("doctor", help="verify the analysis environment (no models, no audio)")
    doctor.add_argument("--schemas", required=True)
    doctor.add_argument("--project-root", default=".")
    doctor.add_argument("--out")

    check = sub.add_parser("schema-check", help="run the shared valid/invalid schema corpus")
    check.add_argument("--schemas", required=True)
    check.add_argument("--fixtures", required=True)
    check.add_argument("--out")

    sub.add_parser("env-info", help="print interpreter facts for environment.json (JSON on stdout)")

    score = sub.add_parser("score", help="score a run (initial analysis, or a rescore into derived/<id>)")
    score.add_argument("--run", required=True)
    score.add_argument("--schemas", default=None)
    score.add_argument("--analysis-id", default="initial")
    score.add_argument("--out-dir", help="rescore target (must be a new directory under the run's derived/)")

    validate = sub.add_parser("validate", help="validate a run directory's artifacts (never modifies the run)")
    validate.add_argument("--run", required=True)
    validate.add_argument("--schemas", default=None)
    validate.add_argument("--stage", choices=["runtime", "initial", "sealed"], default="sealed")
    validate.add_argument("--require-exact-endpoints", action="store_true")
    validate.add_argument("--validation-id")
    validate.add_argument("--out")

    args = parser.parse_args(argv)
    try:
        return _dispatch(args)
    except FileExistsError as exc:
        print(f"{args.operation}: refusing to overwrite an existing artifact: {exc.filename}", file=sys.stderr)
        return 2


def _dispatch(args: argparse.Namespace) -> int:
    if args.operation == "env-info":
        from .doctor import env_info

        sys.stdout.write(json.dumps(env_info(), ensure_ascii=False) + "\n")
        return 0
    if args.operation == "score":
        from .score import initial_validation, score_run
        from .validate import validate_run

        run, schemas = Path(args.run), _schemas(args.schemas)
        try:
            metrics = score_run(run, schemas, args.analysis_id)
        except Exception as exc:  # scoring failure is a typed analysis error (exit 7), raw outputs stay intact
            print(f"score: failed: {type(exc).__name__}: {exc}", file=sys.stderr)
            return 7
        if args.out_dir:
            out = Path(args.out_dir)
            if run.resolve() not in out.resolve().parents or "derived" not in out.parts:
                print("score: --out-dir must be inside the run's derived/ directory", file=sys.stderr)
                return 2
            out.mkdir(parents=True, exist_ok=False)
            _write(metrics, str(out / "metrics.json"), exclusive=True)
            report = validate_run(run, schemas, "sealed", validation_id=f"rescore-{args.analysis_id}")
        else:
            _write(metrics, str(run / "metrics.json"), exclusive=True)
            report = initial_validation(run, schemas)
            out = run
        _write(report, str(out / "validation.json"), exclusive=True)
        accuracy = {k: v["value"] for k, v in metrics["accuracy"].items()}
        print(f"score: accuracy {accuracy}; validation {report['status']}", file=sys.stderr)
        return 0
    if args.operation == "validate":
        from .validate import validate_run

        report = validate_run(Path(args.run), _schemas(args.schemas), args.stage, args.require_exact_endpoints,
                              args.validation_id)
        _write(report, args.out, exclusive=bool(args.out))
        failed = [c["check_id"] for c in report["checks"] if c["status"] == "fail"]
        print(f"validate ({args.stage}): {report['status']}" + (f"; failed: {', '.join(failed)}" if failed else ""),
              file=sys.stderr)
        for item in report["disclosures"]:
            print(f"  disclosed {item['code']}: {item['message']}", file=sys.stderr)
        return 0 if report["status"] == "pass" else 9
    if args.operation == "doctor":
        from . import doctor as doctor_module

        report = doctor_module.run(Path(args.schemas), Path(args.project_root).resolve())
        _write(report, args.out)
        failed = [c["check_id"] for c in report["checks"] if c["status"] != "pass"]
        print(f"doctor: {report['status']}" + (f" (failed: {', '.join(failed)})" if failed else ""), file=sys.stderr)
        return 0 if report["status"] == "pass" else 9
    if args.operation == "schema-check":
        from .schemas import SchemaStore, check_corpus

        report = check_corpus(SchemaStore(Path(args.schemas)), Path(args.fixtures))
        _write(report, args.out)
        bad = report["failures"]
        print(f"schema-check: {report['total']} documents, {len(bad)} unexpected results, "
              f"targets without a valid example: {report['targets_without_valid_example'] or 'none'}", file=sys.stderr)
        return 0 if not bad and not report["targets_without_valid_example"] else 9
    return 2


if __name__ == "__main__":
    sys.exit(main())
