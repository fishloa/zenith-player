#!/bin/bash
# Sign-in check on a paired Apple TV: installs the app, points it at a local
# auth test server, and waits for the device grant and the authorised playlist
# fetch in the server log, plays a test channel and then a channel from the
# restored playlist, and reads the app's playback log for both.
# usage: scripts/verify-auth-on-tv.sh <device-udid> <restore-playlist-url> [device|basic]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$1"; RESTORE="$2"; MODE="${3:-device}"
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
LOG="$ROOT/build/auth-server.log"
python3 "$ROOT/scripts/auth-test-server.py" "$ROOT/testdata/demo-local" 8099 "$MODE" > "$LOG" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
APP_ONLY=1 "$ROOT/scripts/verify-on-tv.sh" 0 "$DEV" | tail -3
APP="$(find "$ROOT/build/app-device/Build/Products" -maxdepth 2 -name '*.app' | head -1)"
BID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
applog() {
  rm -f "$ROOT/build/playback.log"
  xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier "$BID" \
    --source Library/Caches/playback.log --destination "$ROOT/build/playback.log" > /dev/null 2>&1
  grep "playing $1 " "$ROOT/build/playback.log" 2>/dev/null | tail -1
}
PREV_TEST="$(applog big-buck-bunny)"
xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BID" -- -zenithPlaylist "http://$IP:8099/playlist.m3u" -zenithPlayChannel big-buck-bunny > /dev/null
for _ in $(seq 1 60); do
  grep -q "^GET /playlist.m3u 200" "$LOG" && break
  sleep 2
done
cat "$LOG"
grep -q "^GET /playlist.m3u 401" "$LOG" && echo "PASS 401 challenge seen" || echo "FAIL no 401"
[ "$MODE" = device ] && { grep -q "TOKEN ISSUED" "$LOG" && echo "PASS device grant" || echo "FAIL no token"; }
grep -q "^GET /playlist.m3u 200 \(Bearer\|Basic\)" "$LOG" && echo "PASS authorised playlist" || echo "FAIL playlist not authorised"
sleep 30
grep -q "^GET /big-buck-bunny.ts 200 ?t" "$LOG" && echo "PASS stream fetched with ?t token" || echo "FAIL stream not fetched"
L="$(applog big-buck-bunny)"; echo "$L"
[[ "$L" == *"first_frame="[0-9]* && "$L" != "$PREV_TEST" ]] && echo "PASS test channel played" || echo "FAIL test channel did not play"
PREV_RESTORE="$(applog "${RESTORE_CHANNEL:-tf-1}")"
xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BID" -- -zenithPlaylist "$RESTORE" -zenithPlayChannel "${RESTORE_CHANNEL:-tf-1}" > /dev/null
sleep 35
L="$(applog "${RESTORE_CHANNEL:-tf-1}")"; echo "$L"
[[ "$L" == *"first_frame="[0-9]* && "$L" != "$PREV_RESTORE" ]] && echo "PASS ${RESTORE_CHANNEL:-tf-1} played from the restored playlist" || echo "FAIL ${RESTORE_CHANNEL:-tf-1} did not play"
echo "restored playlist; app relaunched on ${RESTORE_CHANNEL:-tf-1}"