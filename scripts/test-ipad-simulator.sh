#!/bin/bash
# Test iPad app on simulator
# Usage: ./scripts/test-ipad-simulator.sh [group]
# Example: ./scripts/test-ipad-simulator.sh France

set -e

IPAD_SIM="1AC7A04C-5ECB-46BD-A2BC-9F5C0426BF14"
DD="/tmp/ipad-dd"
APP="$DD/Build/Products/Debug-iphonesimulator/Zenith Player.app"
GROUP="${1:-}"

echo "=== Building iPad target ==="
xcodebuild -project IPTVPlayer.xcodeproj \
  -scheme "ZenithTV-iPad" \
  -destination "platform=iOS Simulator,id=$IPAD_SIM" \
  -configuration Debug \
  -derivedDataPath "$DD" \
  build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  2>&1 | tail -3

echo ""
echo "=== Booting simulator ==="
xcrun simctl boot "$IPAD_SIM" 2>/dev/null || true
open -a Simulator

echo ""
echo "=== Installing app ==="
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl terminate "$IPAD_SIM" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$IPAD_SIM" "$APP"

echo ""
echo "=== Launching app ==="
if [ -n "$GROUP" ]; then
  echo "    Auto-navigating to: $GROUP"
  xcrun simctl launch "$IPAD_SIM" "$BUNDLE_ID" -openGroup "$GROUP"
else
  xcrun simctl launch "$IPAD_SIM" "$BUNDLE_ID"
fi

echo ""
echo "=== Waiting for app to load ==="
sleep 6

echo ""
echo "=== Taking screenshot ==="
xcrun simctl io "$IPAD_SIM" screenshot /tmp/ipad-test.png
echo "Screenshot: /tmp/ipad-test.png"
