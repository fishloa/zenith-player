#!/bin/bash
# App unit tests (IPTVPlayerTests) on the tvOS simulator, or on a paired
# Apple TV with TEST_DEVICE=<udid> (signs with .env's TEAM_ID and ASC key).
# usage: scripts/test-app.sh [-only-testing:IPTVPlayerTests/SomeTests ...]
# Integration tests against a live server run only when ZENITH_TEST_SERVER is
# set to its base URL (e.g. http://192.168.1.10:8080); otherwise they skip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${TVOS_SIM:-Apple TV 4K (3rd generation)}"
LOG="$ROOT/build/test-app.log"
mkdir -p "$ROOT/build"
cd "$ROOT"
DEST=(-destination "platform=tvOS Simulator,name=$SIM")
if [ -n "${TEST_DEVICE:-}" ]; then
  . "$ROOT/scripts/env.sh"
  KEY_ID="${ASC_KEY_ID:?set ASC_KEY_ID (see .env.example)}"
  DEST=(-destination "id=$TEST_DEVICE" -derivedDataPath "$ROOT/build/test-device"
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration
    -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
    -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" PROVISIONING_PROFILE_SPECIFIER=
    DEVELOPMENT_TEAM="${TEAM_ID:?set TEAM_ID (see .env.example)}")
fi
set +e
TEST_RUNNER_ZENITH_TEST_SERVER="${ZENITH_TEST_SERVER:-}" xcodebuild test \
  -project IPTVPlayer.xcodeproj -scheme IPTVPlayer \
  "${DEST[@]}" \
  "$@" > "$LOG" 2>&1
status=$?
set -e
grep -E "Test Case .* (passed|failed|skipped)|error:|\*\* TEST" "$LOG" | grep -vE "passed" | tail -40
grep -cE "Test Case .* passed" "$LOG" | sed 's/^/passed: /'
exit $status
