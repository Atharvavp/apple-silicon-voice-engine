#!/bin/bash
# V19: enforced-offline end-to-end smoke (plan H3).
#
#   bash scripts/offline_smoke.sh .build/release/voicebench .venv/bin/python evidence/M7/offline
#
# 1. Control test: a local TCP listener started OUTSIDE the sandbox is reachable
#    without the sandbox (positive control) and refused with EPERM inside it
#    (the denial comes from the policy, not from an absent network). An outbound
#    connection attempt inside the sandbox must also fail with a permission error.
# 2. The already-built binary and the installed Python environment then run the
#    full e2e sequence under the same deny-network policy, with a fresh HOME and
#    empty model/cache directories that must still be empty afterwards.
# Nothing is fetched or built here. Environment flags are supplemental only.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
vb="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
py="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
out="$3"
case "$out" in /*) ;; *) out="$root/$out" ;; esac
rm -rf "$out" && mkdir -p "$out"
policy='(version 1)(allow default)(deny network*)'
sandbox=/usr/bin/sandbox-exec
fresh="$(mktemp -d "${TMPDIR:-/tmp}/voicebench-offline.XXXXXX")"
mkdir -p "$fresh/home" "$fresh/cache" "$fresh/hf"

"$py" - "$out/control.json" "$sandbox" "$policy" <<'PY'
import json, socket, subprocess, sys, threading
out, sandbox, policy = sys.argv[1:4]
server = socket.socket(); server.bind(("127.0.0.1", 0)); server.listen(4)
port = server.getsockname()[1]
threading.Thread(target=lambda: [server.accept() for _ in range(4)], daemon=True).start()
probe = ("import socket,sys\n"
         "def attempt(host, port):\n"
         "    try:\n"
         "        socket.create_connection((host, port), timeout=3).close(); return 'connected'\n"
         "    except PermissionError as e: return f'denied: {e}'\n"
         "    except OSError as e: return f'oserror: {e}'\n"
         f"print(attempt('127.0.0.1', {port})); print(attempt('1.1.1.1', 443))\n")
plain = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True, timeout=30)
boxed = subprocess.run([sandbox, "-p", policy, sys.executable, "-c", probe], capture_output=True, text=True, timeout=30)
plain_local = plain.stdout.splitlines()[0] if plain.stdout else plain.stderr
boxed_lines = boxed.stdout.splitlines()
result = {"policy": policy, "sandbox_exec": sandbox, "sandbox_exit_code": boxed.returncode,
          "sandbox_stderr": boxed.stderr[-500:],
          "outside_sandbox_local_listener": plain_local,
          "inside_sandbox_local_listener": boxed_lines[0] if boxed_lines else None,
          "inside_sandbox_outbound_1_1_1_1_443": boxed_lines[1] if len(boxed_lines) > 1 else None}
result["denial_enforced"] = (plain_local == "connected" and boxed.returncode == 0
                             and all(line.startswith("denied") for line in boxed_lines[:2]) and len(boxed_lines) >= 2)
json.dump(result, open(out, "w"), indent=2)
print(json.dumps(result, indent=2))
sys.exit(0 if result["denial_enforced"] else 1)
PY
control=$?

e2e=1
if [ "$control" -eq 0 ]; then
  env -i HOME="$fresh/home" XDG_CACHE_HOME="$fresh/cache" HF_HOME="$fresh/hf" HF_HUB_OFFLINE=1 \
      TRANSFORMERS_OFFLINE=1 PATH=/usr/bin:/bin TMPDIR="$fresh" \
      "$sandbox" -p "$policy" "$py" "$root/scripts/e2e.py" --voicebench "$vb" --out "$out/e2e" > "$out/e2e.log" 2>&1
  e2e=$?
fi
models_empty=$([ -z "$(ls -A "$fresh/hf")" ] && [ -z "$(find "$fresh/cache" -type f 2>/dev/null)" ] && echo true || echo false)
"$py" - "$out" "$control" "$e2e" "$models_empty" "$vb" <<'PY'
import hashlib, json, sys, pathlib
out, control, e2e, empty, vb = sys.argv[1:6]
out = pathlib.Path(out)
report = {"control_exit": int(control), "e2e_exit": int(e2e), "model_and_hub_caches_empty_after": empty == "true",
          "voicebench_sha256": hashlib.sha256(pathlib.Path(vb).read_bytes()).hexdigest(),
          "status": "pass" if control == "0" and e2e == "0" and empty == "true" else "fail"}
commands = out / "e2e/commands.json"
if commands.exists():
    data = json.loads(commands.read_text())
    report["e2e_steps"] = len(data["steps"]); report["e2e_status"] = data["status"]
(out / "offline.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"offline smoke: {report['status']}")
PY
rm -rf "$fresh"
[ "$control" -eq 0 ] && [ "$e2e" -eq 0 ] && [ "$models_empty" = true ]
