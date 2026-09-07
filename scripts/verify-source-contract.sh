#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
project="$root/celesti.xcodeproj/project.pbxproj"
resolved="$root/celesti.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
expected_sabella_revision="39093d503a6f5950c504855105cb7c3b6ab8c6f1"

if grep -Eq 'XCLocalSwiftPackageReference|relativePath = .*sabella' "$project"; then
  echo "Atlantide must not depend on a local Sabella checkout" >&2
  exit 1
fi

grep -Fq 'repositoryURL = "https://github.com/gaulatti/sabella.git";' "$project"
grep -Fq "revision = $expected_sabella_revision;" "$project"

jq -e --arg revision "$expected_sabella_revision" '
  .pins | any(
    .identity == "sabella"
    and .kind == "remoteSourceControl"
    and .location == "https://github.com/gaulatti/sabella.git"
    and .state.revision == $revision
  )
' "$resolved" >/dev/null

if [ -e "$root/celesti.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/workspace-state.json" ] \
  && git -C "$root" ls-files --error-unmatch \
  celesti.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/workspace-state.json \
  >/dev/null 2>&1; then
  echo "machine-specific SwiftPM workspace-state.json must not be tracked" >&2
  exit 1
fi

grep -Fq 'static let productionBaseURL = URL(string: "https://api.celesti.gaulatti.com")!' \
  "$root/celesti/CelestiAPIConfiguration.swift"

echo "source_contract=ok"
echo "sabella_revision=$expected_sabella_revision"
