#!/bin/sh
# Export the Swift package's coverage as lcov after `swift test --enable-code-coverage`.
#
# Usage: clouseau-coverage.sh [ROOT]   (ROOT defaults to this repository; CI also runs it on a
# detached base-revision checkout). Writes ROOT/coverage/llvm.lcov (ignored) with workspace-relative
# `SF:` paths so another machine can read it.
#
# Every Swift file under celesti/ is reported. The SwiftPM target compiles only a subset (the rest
# needs tvOS, AVKit or VLC), so llvm-cov cannot see the others. Each of those gets a record with a
# zero-hit `DA` entry for every non-blank, non-comment line: an untested file counts as uncovered
# rather than silently passing. This is a deliberate approximation of its executable lines; it is
# applied identically to the base and the pull request, so the regression comparison stays exact.
# llvm-cov's lcov has no BRDA records, so only lines are measured, never branches.
set -eu
root=$(CDPATH= cd -- "${1:-$(dirname -- "$0")/..}" && pwd -P)
cd "$root"
bin=$(swift build --show-bin-path)
mkdir -p coverage
find celesti -name '*.swift' | LC_ALL=C sort > coverage/swift-sources.txt
# shellcheck disable=SC2046
xcrun llvm-cov export -format=lcov \
  -instr-profile="$bin/codecov/default.profdata" \
  "$bin/AtlantideResilienceTests.xctest/Contents/MacOS/AtlantideResilienceTests" \
  $(cat coverage/swift-sources.txt) \
  | sed "s#^SF:$root/#SF:#" > coverage/llvm.lcov
while IFS= read -r file; do
  grep -qx "SF:$file" coverage/llvm.lcov && continue
  {
    echo "SF:$file"
    awk '/[^[:space:]]/ && !/^[[:space:]]*\/\// { print "DA:" NR ",0"; n++ } END { print "LF:" n+0; print "LH:0" }' "$file"
    echo "BRF:0"
    echo "BRH:0"
    echo "end_of_record"
  } >> coverage/llvm.lcov
done < coverage/swift-sources.txt
rm coverage/swift-sources.txt
