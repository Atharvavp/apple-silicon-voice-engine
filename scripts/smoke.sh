#!/usr/bin/env bash
# Model-free smoke run of the default harness (run scripts/setup.sh first):
#
#   bash scripts/smoke.sh [--out NEW_DIRECTORY]
#
# Uses the committed 12-second synthetic fixture (tones and silence, 16 kHz,
# 192,000 samples) with the deterministic mock adapters in step mode. No models,
# datasets, accounts, microphone or network are used. It builds the default
# PHASE1_FRAMEWORKS=none release binary if needed, then runs, validates and
# exports one experiment and checks the result (scripts/smoke_check.py).
#
# Output goes to a NEW directory: --out must not exist, and the default is a
# fresh runs/smoke-<timestamp>-<pid>/ (git-ignored). Existing output is never
# overwritten or deleted.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
py="$root/.venv/bin/python"
vb="$root/.build/release/voicebench"
out=""

fail() { echo "smoke: error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) [ $# -ge 2 ] || fail "--out needs a path"; out="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

[ -x "$py" ] || fail "$py not found; run bash scripts/setup.sh first"
if [ -z "$out" ]; then
  out="$root/runs/smoke-$(date +%Y%m%d-%H%M%S)-$$"
fi
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
[ ! -e "$out" ] || fail "$out already exists; choose a new --out (smoke never overwrites or deletes output)"

lock_before="$(shasum -a 256 "$root/Package.resolved" | cut -d' ' -f1)"
(cd "$root" && PHASE1_FRAMEWORKS=none swift build --disable-keychain -c release) >/dev/null
[ "$(shasum -a 256 "$root/Package.resolved" | cut -d' ' -f1)" = "$lock_before" ] \
  || echo "smoke: warning: the build rewrote Package.resolved; review it with 'git diff Package.resolved'" >&2
version="$("$vb" --version)"
case "$version" in
  *"phase1 frameworks: none"*) ;;
  *) fail "$vb reports '$version'; the smoke path expects the default mock-only build" ;;
esac

mkdir -p "$out"
run="$out/runs/smoke"
echo "voicebench $version"
echo "== run (step mode, mock adapters)"
(cd "$root" && "$vb" run --config configs/mock-step.yaml --runs-dir "$out/runs" --run-id smoke)
echo "== validate (writes a new derived/validation-*/ report; sealed artifacts are not changed)"
(cd "$root" && "$vb" validate --run "$run")
echo "== export (CSV and PNG)"
(cd "$root" && "$vb" export --run "$run" --out "$out/export")
echo "== check"
PYTHONDONTWRITEBYTECODE=1 "$py" "$root/scripts/smoke_check.py" --run "$run" --export "$out/export"

cat <<EOF

Smoke run passed. Output: $out
  runs/smoke/status.json            state and the SHA-256 of every sealed artifact
  runs/smoke/runtime_summary.json   sample accounting (coverage), queue depths, phase durations
  runs/smoke/predictions.json       final transcript and speaker segments (scripted mock output)
  runs/smoke/metrics.json           WER/CER/DER/JER, timing and resource metrics
  runs/smoke/validation.json        initial validation; runs/smoke/derived/ holds the new one
  export/                           CSV tables and PNG plots
The scores are deliberately imperfect scripted mock output on tones and silence; they test the
harness and scorers, not speech recognition.
EOF
