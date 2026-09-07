#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <physical-device-id> <marketing-version> <build-number> <output-directory>" >&2
  exit 64
fi

device_id="$1"
marketing_version="$2"
build_number="$3"
output_directory="$4"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [ "$(xcodebuild -version | sed -n '1p')" != "Xcode 26.6" ]; then
  echo "internal builds require Xcode 26.6" >&2
  exit 1
fi

if ! [[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "marketing version must be an explicit three-part version" >&2
  exit 64
fi
if ! [[ "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "build number must be a positive integer" >&2
  exit 64
fi
if [ -n "$(git -C "$root" status --porcelain --untracked-files=all)" ]; then
  echo "internal builds require a clean checkout" >&2
  exit 1
fi

mkdir -p "$output_directory"
output_directory="$(cd "$output_directory" && pwd -P)"
case "$output_directory/" in
  "$root/"*) echo "output directory must be outside the checkout" >&2; exit 64 ;;
esac

git_sha="$(git -C "$root" rev-parse HEAD)"
derived_data="$output_directory/DerivedData"
source_packages="$output_directory/SourcePackages"

"$root/scripts/verify-source-contract.sh"

xcodebuild \
  -quiet \
  -resolvePackageDependencies \
  -project "$root/celesti.xcodeproj" \
  -scheme celesti \
  -clonedSourcePackagesDirPath "$source_packages"

xcodebuild \
  -quiet \
  -project "$root/celesti.xcodeproj" \
  -scheme celesti \
  -configuration Release \
  -destination "platform=tvOS,id=$device_id" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  ATLANTIDE_GIT_SHA="$git_sha" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build

app="$derived_data/Build/Products/Release-appletvos/celesti.app"
"$root/scripts/verify-internal-app.sh" \
  "$app" "$marketing_version" "$build_number" "$git_sha" signed

echo "app=$app"
echo "device_id=$device_id"
