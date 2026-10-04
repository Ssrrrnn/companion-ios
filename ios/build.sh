#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
overrides=()
if [[ -n "${APP_BUILD_VERSION:-}" ]]; then
  [[ "$APP_BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'Invalid build version' >&2; exit 1; }
  overrides+=("CURRENT_PROJECT_VERSION=$APP_BUILD_VERSION")
fi
xcodegen generate
xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "${overrides[@]}" build
rm -rf build/package
mkdir -p build/package/Payload
cp -R build/Build/Products/Release-iphoneos/Companion.app build/package/Payload/
rm -f build/Companion.ipa
(cd build/package && zip -qry ../Companion.ipa Payload)
printf 'Unsigned IPA: %s/build/Companion.ipa\n' "$PWD"
