#!/bin/bash
# Capture the actual SwiftUI client with synthetic messages; never connects to a backend.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/previews
xcodegen generate
SIMULATOR_ID=$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[v["udid"] for runtime, devices in d["devices"].items() if "iOS" in runtime for v in devices if v["name"].startswith("iPhone")]; print(ids[0])')
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Debug \
  -sdk iphonesimulator -destination "id=$SIMULATOR_ID" -derivedDataPath build-simulator \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build > build/previews/build.log 2>&1 || { tail -80 build/previews/build.log; exit 1; }
xcodebuild -project Companion.xcodeproj -scheme Companion -configuration Debug \
  -sdk iphonesimulator -destination "id=$SIMULATOR_ID" -derivedDataPath build-simulator \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test > build/previews/tests.log 2>&1 || { tail -100 build/previews/tests.log; exit 1; }
xcrun simctl install "$SIMULATOR_ID" build-simulator/Build/Products/Debug-iphonesimulator/Companion.app
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl ui "$SIMULATOR_ID" appearance light
xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview
sleep 4
xcrun simctl io "$SIMULATOR_ID" screenshot build/previews/chat-light.png
xcrun simctl ui "$SIMULATOR_ID" appearance dark
sleep 2
xcrun simctl io "$SIMULATOR_ID" screenshot build/previews/chat-dark.png
xcrun simctl terminate "$SIMULATOR_ID" com.ssrrrnn.companion
xcrun simctl ui "$SIMULATOR_ID" appearance light
xcrun simctl launch "$SIMULATOR_ID" com.ssrrrnn.companion --ui-preview --home
sleep 3
xcrun simctl io "$SIMULATOR_ID" screenshot build/previews/home-light.png
xcrun simctl terminate "$SIMULATOR_ID" com.ssrrrnn.companion
