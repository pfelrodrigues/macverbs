#!/usr/bin/env bash
# Run `swift test`, bridging Swift Testing when only Command Line Tools are installed
# (no full Xcode). Full Xcode already exposes Testing/XCTest; bare `swift test` works.
set -euo pipefail

xcode_path="$(xcode-select -p 2>/dev/null || true)"
clt_fw="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
clt_lib="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [[ "$xcode_path" == *CommandLineTools* ]] && [[ -d "$clt_fw/Testing.framework" ]]; then
  export DYLD_FRAMEWORK_PATH="${clt_fw}${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
  export DYLD_LIBRARY_PATH="${clt_lib}${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  exec swift test \
    -Xswiftc -F -Xswiftc "$clt_fw" \
    -Xlinker -F -Xlinker "$clt_fw" \
    -Xlinker -L -Xlinker "$clt_lib" \
    -Xlinker -rpath -Xlinker "$clt_fw" \
    -Xlinker -rpath -Xlinker "$clt_lib" \
    "$@"
fi

exec swift test "$@"
