#!/bin/bash
# Capture the actual SwiftUI client with synthetic messages; never connects to a backend.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/previews
xcodegen generate
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for runtime, devices in d["devices"].items() if "iOS" in runtime for v in devices if v["name"].startswith("iPhone")]; print(ids[0])')
xcrun simctl boot "$SIMULATOR_ID" || true
python3 - "$SIMULATOR_ID" <<'PYBOOT'
import subprocess, sys
subprocess.run(['xcrun', 'simctl', 'bootstatus', sys.argv[1], '-b'], check=True, timeout=180)
PYBOOT
test_exit=0
xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Debug \
  -sdk iphonesimulator -destination "id=$SIMULATOR_ID" -derivedDataPath build-simulator \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -parallel-testing-enabled NO test > build/previews/tests.log 2>&1 || { test_exit=$?; grep -E 'error:|Test Case.*failed|Executed' build/previews/tests.log || true; tail -60 build/previews/tests.log; }
xcrun simctl install "$SIMULATOR_ID" build-simulator/Build/Products/Debug-iphonesimulator/Companion.app
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
# Launch in each appearance so screenshots also verify a cold dark-mode start.
for page in chat home books calendar activity mood-editor; do
  for appearance in light dark; do
    xcrun simctl terminate "$SIMULATOR_ID" com.ssrrrnn.companion || true
    xcrun simctl ui "$SIMULATOR_ID" appearance "$appearance"
    if [ "$page" = home ]; then
      xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --home --reset-draft -AppleLocale zh_CN -AppleLanguages '(zh-Hans)'
    elif [ "$page" = mood-editor ]; then
      xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --calendar --mood-editor --reset-draft -AppleLocale zh_CN -AppleLanguages '(zh-Hans)'
    elif [ "$page" = activity ]; then
      xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --activity --reset-draft -AppleLocale zh_CN -AppleLanguages '(zh-Hans)'
    elif [ "$page" = calendar ]; then
      xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --calendar --reset-draft -AppleLocale zh_CN -AppleLanguages '(zh-Hans)'
    elif [ "$page" = books ]; then
      xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --books --reset-draft -AppleLocale zh_CN -AppleLanguages '(zh-Hans)'
    else
      xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --reset-draft -AppleLocale zh_CN -AppleLanguages '(zh-Hans)'
    fi
    sleep 4
    xcrun simctl io "$SIMULATOR_ID" screenshot "build/previews/$page-$appearance.png"
  done
done
xcrun simctl terminate "$SIMULATOR_ID" com.ssrrrnn.companion
exit "$test_exit"
