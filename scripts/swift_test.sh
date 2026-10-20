#!/bin/bash
# Runs `swift test` with the Swift Testing framework paths that SwiftPM does
# not add automatically when only the Command Line Tools are installed (no
# Xcode, therefore no XCTest). With a full Xcode selected the extra flags are
# skipped. All arguments are forwarded, e.g. `scripts/swift_test.sh --filter ClockTests`.
# An explicit DEVELOPER_DIR takes precedence over the global `xcode-select` choice.
set -euo pipefail
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
flags=()
if [[ "$developer_dir" == *CommandLineTools* ]]; then
  fw="$developer_dir/Library/Developer/Frameworks"
  lib="$developer_dir/Library/Developer/usr/lib"
  if [[ ! -d "$fw/Testing.framework" ]]; then
    echo "error: Swift Testing framework not found under $fw" >&2
    exit 2
  fi
  flags=(-Xswiftc "-F$fw" -Xlinker "-F$fw" -Xlinker -rpath -Xlinker "$fw" -Xlinker -rpath -Xlinker "$lib")
fi
exec swift test "${flags[@]}" "$@"
