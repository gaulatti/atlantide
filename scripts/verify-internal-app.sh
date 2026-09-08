#!/bin/bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 5 ]; then
  echo "usage: $0 <celesti.app> <marketing-version> <build-number> <git-sha> [signed|unsigned]" >&2
  exit 64
fi

app="$1"
expected_version="$2"
expected_build="$3"
expected_sha="$4"
signing_mode="${5:-signed}"
info="$app/Info.plist"

case "$signing_mode" in
  signed|unsigned) ;;
  *) echo "signing mode must be signed or unsigned" >&2; exit 64 ;;
esac

test -d "$app"
test -f "$info"
test "$expected_sha" != "UNSET"
test "$expected_sha" != "local"

plist_value() {
  plutil -extract "$1" raw -o - "$info"
}

bundle_id="$(plist_value CFBundleIdentifier)"
version="$(plist_value CFBundleShortVersionString)"
build="$(plist_value CFBundleVersion)"
git_sha="$(plist_value AtlantideGitSHA)"
executable="$(plist_value CFBundleExecutable)"
binary="$app/$executable"

test "$bundle_id" = "com.gaulatti.celesti"
test "$version" = "$expected_version"
test "$build" = "$expected_build"
test "$git_sha" = "$expected_sha"
test -x "$binary"

if [ "$signing_mode" = "signed" ]; then
  codesign --verify --deep --strict "$app"
else
  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    echo "expected an unsigned CI artifact" >&2
    exit 1
  fi
fi

if ! strings "$binary" | grep -F 'https://api.celesti.gaulatti.com' >/dev/null; then
  echo "Release binary is missing the production API base" >&2
  exit 1
fi
if strings "$binary" | grep -F 'CELESTI_API_BASE_URL' >/dev/null; then
  echo "Release binary contains the Debug-only API override" >&2
  exit 1
fi

binary_sha256="$(shasum -a 256 "$binary" | awk '{print $1}')"

echo "bundle_id=$bundle_id"
echo "marketing_version=$version"
echo "build_number=$build"
echo "git_sha=$git_sha"
echo "binary_sha256=$binary_sha256"
echo "signing_mode=$signing_mode"

if [ "$signing_mode" = "signed" ]; then
  codesign -d --verbose=4 "$app" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|CDHash)='
fi
