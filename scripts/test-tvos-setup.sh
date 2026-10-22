#!/bin/bash
# First-run check on the tvOS simulator: fresh install shows setup (or, with a
# Zenith server advertising on this network, the channels it found).
# usage: scripts/test-tvos-setup.sh   → $SHOTS/setup-1.png (2 s), setup-2.png (12 s); simctl cannot write to external volumes
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${TVOS_SIM_ID:-1761D772-406A-4ED9-B979-88626968B588}"
SHOTS="${SHOTS:-/tmp/zenith-setup}"; mkdir -p "$SHOTS"
DD="$ROOT/build/sim-dd"
xcodebuild -project "$ROOT/IPTVPlayer.xcodeproj" -scheme IPTVPlayer -destination "platform=tvOS Simulator,id=$SIM" \
  -derivedDataPath "$DD" build -quiet > "$ROOT/build/sim-build.log" 2>&1
APP="$DD/Build/Products/Debug-appletvsimulator/Zenith Player.app"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl uninstall "$SIM" "$BID" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$BID" >/dev/null
sleep 2;  xcrun simctl io "$SIM" screenshot "$SHOTS/setup-1.png" >/dev/null
sleep 10; xcrun simctl io "$SIM" screenshot "$SHOTS/setup-2.png" >/dev/null
echo "bundle $BID; screenshots in $SHOTS"
