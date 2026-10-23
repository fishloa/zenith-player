#!/bin/bash
# Sign-in check on the tvOS simulator against scripts/auth-test-server.py.
# usage: scripts/test-auth-simulator.sh [device|basic]
#   → $SHOTS/auth-1.png (sign-in screen), auth-2.png (after the grant), server log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-device}"
SIM="${TVOS_SIM_ID:-1761D772-406A-4ED9-B979-88626968B588}"
SHOTS="${SHOTS:-/tmp/zenith-auth}"; mkdir -p "$SHOTS"
DD="$ROOT/build/sim-dd"
LOG="$ROOT/build/auth-server-sim.log"
python3 "$ROOT/scripts/auth-test-server.py" "$ROOT/testdata/demo-local" 8099 "$MODE" > "$LOG" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
xcodebuild -project "$ROOT/IPTVPlayer.xcodeproj" -scheme IPTVPlayer -destination "platform=tvOS Simulator,id=$SIM" \
  -derivedDataPath "$DD" build -quiet > "$ROOT/build/sim-build.log" 2>&1 || { echo "build failed"; exit 1; }
APP="$DD/Build/Products/Debug-appletvsimulator/Zenith Player.app"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl uninstall "$SIM" "$BID" 2>/dev/null || true
xcrun simctl install "$SIM" "$APP"
xcrun simctl launch "$SIM" "$BID" -zenithPlaylist http://127.0.0.1:8099/playlist.m3u > /dev/null
sleep 5; xcrun simctl io "$SIM" screenshot "$SHOTS/auth-1.png" > /dev/null 2>&1
sleep 15; xcrun simctl io "$SIM" screenshot "$SHOTS/auth-2.png" > /dev/null 2>&1
cat "$LOG"
echo "screenshots in $SHOTS"
