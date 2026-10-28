#!/usr/bin/env bash
# One-time setup for the default (mock-only) harness:
#
#   bash scripts/setup.sh [--python /path/to/python3.12] [--skip-build]
#
# 1. Prints host/toolchain diagnostics (macOS, architecture, Swift, developer directory).
# 2. Selects Python 3.12 (--python, else `python3.12` on PATH) and checks its version
#    before touching anything.
# 3. Creates <repo>/.venv, or reuses it if it already runs Python 3.12. An existing .venv
#    with another interpreter is never replaced or deleted: setup stops instead.
# 4. Installs the hash-locked analysis environment (pip --require-hashes), then runs
#    `pip check` and the analysis doctor.
# 5. Builds the default PHASE1_FRAMEWORKS=none release binary (mock adapters only) and
#    checks that the build left Package.resolved unchanged.
#
# Network is needed for PyPI and SwiftPM downloads. Setup never installs Homebrew,
# Xcode or Command Line Tools, never uses sudo, never downloads models or datasets and
# never accepts any license. Rerunning it is safe: pinned packages that are already
# installed are left as they are and the lock files are not regenerated.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$root/analysis/requirements-dev-macos-arm64-py312.lock"
venv="$root/.venv"
python=""
build=1

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
fail() { echo "setup: error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --python) [ $# -ge 2 ] || fail "--python needs a path"; python="$2"; shift 2 ;;
    --skip-build) build=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

echo "== host"
[ "$(uname -s)" = Darwin ] || fail "the Swift harness needs macOS (found $(uname -s)); see docs/development.md for the Linux Python-only checks"
arch="$(uname -m)"
echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $arch"
if [ "$arch" != arm64 ]; then
  echo "setup: warning: only arm64 (Apple Silicon) has been tested; continuing on $arch" >&2
fi
command -v swift >/dev/null 2>&1 || fail "swift not found; install Xcode or the Command Line Tools (xcode-select --install) yourself, then rerun"
echo "developer dir: ${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo unknown)}"
swift --version 2>&1 | head -1

echo "== python"
if [ -z "$python" ]; then
  python="$(command -v python3.12 || true)"
  [ -n "$python" ] || fail "python3.12 not found on PATH; install Python 3.12 and rerun, or pass --python /path/to/python3.12"
fi
[ -x "$python" ] || fail "$python is not an executable file"
version="$("$python" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)" \
  || fail "$python could not report its version"
case "$version" in
  3.12.*) echo "interpreter: $python ($version)" ;;
  *) fail "$python is Python $version; the analysis package requires 3.12 (analysis/pyproject.toml)" ;;
esac

if [ -e "$venv" ]; then
  [ -x "$venv/bin/python" ] || fail "$venv exists but has no bin/python; move it aside yourself (setup never deletes it)"
  existing="$("$venv/bin/python" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null || echo unknown)"
  case "$existing" in
    3.12.*) echo "reusing $venv (Python $existing)" ;;
    *) fail "$venv uses Python $existing, not 3.12; move it aside yourself (setup never replaces or deletes it)" ;;
  esac
else
  echo "creating $venv"
  "$python" -m venv "$venv"
fi

echo "== analysis dependencies (hash-locked; needs network the first time)"
"$venv/bin/python" -m pip install --disable-pip-version-check --no-input --require-hashes -r "$lock"
"$venv/bin/python" -m pip check

echo "== doctor"
doctor="$(mktemp "${TMPDIR:-/tmp}/voicebench-doctor.XXXXXX")"
if ! PYTHONPATH="$root/analysis/src" PYTHONDONTWRITEBYTECODE=1 MPLBACKEND=Agg \
    "$venv/bin/python" -m phase0_analysis doctor --schemas "$root/schemas/v1" --project-root "$root" --out "$doctor"; then
  fail "doctor failed; report: $doctor"
fi
rm -f "$doctor"

if [ "$build" -eq 1 ]; then
  echo "== swift build (PHASE1_FRAMEWORKS=none, release; mock adapters only)"
  lock_before="$(shasum -a 256 "$root/Package.resolved" | cut -d' ' -f1)"
  (cd "$root" && PHASE1_FRAMEWORKS=none swift build --disable-keychain -c release)
  lock_after="$(shasum -a 256 "$root/Package.resolved" | cut -d' ' -f1)"
  if [ "$lock_before" != "$lock_after" ]; then
    echo "setup: warning: the build rewrote Package.resolved; review it with 'git diff Package.resolved'" >&2
  fi
  "$root/.build/release/voicebench" --version
fi

echo
echo "setup complete. Next: bash scripts/smoke.sh"
