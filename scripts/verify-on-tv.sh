#!/bin/bash
# End-to-end verification on the Apple TV, back to back so the TV never sits
# without an app holding its idle timer off:
#   1. player harness on the bundled captures (PLAYER PASS/FAIL per stream)
#   2. live soak: playlist channels through the pipeline (SOAK PASS/FAIL);
#      CHANNELS=a,b,c limits it (default: a codec/scan/audio cross-section)
#   3. build + install the real Zenith app (replaces the TestFlight build) and launch it
# The Release configuration signs manually for the App Store; the device
# build overrides that with automatic development signing.
# usage: scripts/verify-on-tv.sh [soak-seconds=60] [device-udid]
#        APP_ONLY=1 scripts/verify-on-tv.sh 0 <udid>   # just build + install + launch the app
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-60}"
# One channel per distinct path: 1080i E-AC-3, 1080i, multi-audio, early-video
# mux, 720p HW, HEVC, AC-3, MBAFF+MP2, 576i SD MP2, anamorphic SD. CHANNELS=all
# soaks the whole playlist.
CHANNELS="${CHANNELS:-tf-1,france-2,arte,bfm-tv,orf1,rai-news-24,rai-1,rai-2,rai-gulp,melodie}"
DEV="${2:-$(xcrun devicectl list devices 2>/dev/null | awk '/AppleTV/ && /physical/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')}"
[ -n "$DEV" ] || { echo "no Apple TV found" >&2; exit 1; }
OUT="$ROOT/testdata/verify-$(date +%Y%m%d-%H%M)"; mkdir -p "$OUT"
. "$ROOT/scripts/env.sh"
KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID (see .env.example)}"; ISSUER="${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"

if [ -z "${APP_ONLY:-}" ]; then
echo "== 1/3 player harness"
"$ROOT/tools/decode-probe/run-on-device.sh" "$DEV" -playerOnly | tee "$OUT/harness.txt" | grep PLAYER
echo "== 2/3 live soak (${SECS}s per channel)"
WAIT_FOR="PROBE SOAK DONE" "$ROOT/tools/decode-probe/run-on-device.sh" "$DEV" -playerOnly -soak "$SECS" $([ "$CHANNELS" = all ] || echo -channels "$CHANNELS") | tee "$OUT/soak.txt" | grep SOAK
fi
echo "== 3/3 Zenith app"
xcodebuild -project "$ROOT/IPTVPlayer.xcodeproj" -scheme IPTVPlayer -destination "id=$DEV" -configuration Release \
  -derivedDataPath "$ROOT/build/app-device" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8 \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER= DEVELOPMENT_TEAM="${TEAM_ID:?set TEAM_ID (see .env.example)}" \
  build -quiet > "$OUT/app-build.log" 2>&1 \
  || { echo "app build failed — see $OUT/app-build.log"; exit 1; }
APP="$(find "$ROOT/build/app-device/Build/Products" -maxdepth 2 -name '*.app' | head -1)"
xcrun devicectl device install app --device "$DEV" "$APP" > "$OUT/app-install.log" 2>&1 && echo "installed $(basename "$APP")"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun devicectl device process launch --device "$DEV" "$BID" > "$OUT/app-launch.log" 2>&1 && echo "launched $BID"
echo "results in $OUT"
