#!/bin/bash
# Build, install and run the decode probe on a paired Apple TV; print PROBE lines.
# Signing uses the App Store Connect API key (no Xcode account needed).
# usage: tools/decode-probe/run-on-device.sh [device-udid] [app args, e.g. -playerOnly]
#   default device: first physical Apple TV listed by devicectl
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
. "$HERE/../../scripts/env.sh"
KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID (see .env.example)}"
ISSUER="${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${PROBE_BUNDLE_ID:?set PROBE_BUNDLE_ID}" "${TEAM_ID:?set TEAM_ID}"
export PROBE_BUNDLE_ID TEAM_ID
DEV="${1:-}"; [ -n "$DEV" ] || DEV="$(xcrun devicectl list devices 2>/dev/null | awk '/AppleTV/ && /physical/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{8}-/) {print $i; exit}}')"
[ -n "$DEV" ] || { echo "no Apple TV found" >&2; exit 1; }
[ -d Fixtures ] || ./prepare-fixtures.sh
xcodegen generate -q
xcodebuild -project DecodeProbe.xcodeproj -scheme DecodeProbe -destination "id=$DEV" -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8 \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER" build -quiet
xcrun devicectl device install app --device "$DEV" build/Build/Products/Release-appletvos/DecodeProbe.app >/dev/null
LOG="$(mktemp)"
shift || true
xcrun devicectl device process launch --device "$DEV" --console --terminate-existing "$PROBE_BUNDLE_ID" -- ${ZENITH_URL:+-playlist "$ZENITH_URL/playlist.m3u"} "$@" > "$LOG" 2>&1 &
PID=$!
MARK="${WAIT_FOR:-PROBE PLAYER DONE}"
# A --console launch sometimes hangs without starting the app: relaunch plainly and follow probe.log.
for _ in $(seq 1 12); do [ -s "$LOG" ] && break; sleep 5; done
if [ ! -s "$LOG" ]; then
  kill "$PID" 2>/dev/null || true
  xcrun devicectl device process launch --device "$DEV" --terminate-existing "$PROBE_BUNDLE_ID" -- ${ZENITH_URL:+-playlist "$ZENITH_URL/playlist.m3u"} "$@" >/dev/null 2>&1 || true
  sleep 10
fi
for _ in $(seq 1 1200); do
  grep -q "$MARK" "$LOG" && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 5
done
kill "$PID" 2>/dev/null || true
if ! grep -q "$MARK" "$LOG"; then
  if grep -qE "System is asleep|failed:" "$LOG"; then
    grep -m1 -oE "System is asleep[^\"]*|failed:.*" "$LOG" >&2
  else
    # Console detached but the app keeps running: follow Library/Caches/probe.log instead.
    echo "console detached; following the app's Library/Caches/probe.log" >&2
    COPY="$(mktemp -d)"
    for _ in $(seq 1 600); do
      xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer \
        --domain-identifier "$PROBE_BUNDLE_ID" --source Library/Caches/probe.log --destination "$COPY/probe.log" >/dev/null 2>&1 || true
      grep -q "$MARK" "$COPY/probe.log" 2>/dev/null && break
      # The app was backgrounded/killed (someone used the TV, it slept): stop waiting.
      if ! xcrun devicectl device info processes --device "$DEV" 2>/dev/null | grep -q DecodeProbe.app; then
        echo "app no longer running on the device; giving up" >&2; break
      fi
      sleep 15
    done
    cat "$COPY/probe.log" >> "$LOG" 2>/dev/null || true
  fi
fi
grep '^PROBE ' "$LOG" | awk '!seen[$0]++'
