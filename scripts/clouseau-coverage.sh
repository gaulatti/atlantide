#!/bin/sh
# Export the Swift package's LLVM coverage after `swift test --enable-code-coverage`
# for the local Clouseau review. Writes coverage/llvm.json (ignored).
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
bin=$(swift build --show-bin-path)
mkdir -p coverage
xcrun llvm-cov export -format=text \
  -instr-profile="$bin/codecov/default.profdata" \
  "$bin/AtlantideResilienceTests.xctest/Contents/MacOS/AtlantideResilienceTests" \
  -ignore-filename-regex='Tests|\.build' > coverage/llvm.json
