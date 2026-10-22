#!/bin/bash
# App unit tests (IPTVPlayerTests) on the tvOS simulator.
# usage: scripts/test-app.sh [-only-testing:IPTVPlayerTests/SomeTests ...]
# Integration tests against a live server run only when ZENITH_TEST_SERVER is
# set to its base URL (e.g. http://192.168.1.10:8080); otherwise they skip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${TVOS_SIM:-Apple TV 4K (3rd generation)}"
LOG="$ROOT/build/test-app.log"
mkdir -p "$ROOT/build"
cd "$ROOT"
set +e
TEST_RUNNER_ZENITH_TEST_SERVER="${ZENITH_TEST_SERVER:-}" xcodebuild test \
  -project IPTVPlayer.xcodeproj -scheme IPTVPlayer \
  -destination "platform=tvOS Simulator,name=$SIM" \
  "$@" > "$LOG" 2>&1
status=$?
set -e
grep -E "Test Case .* (passed|failed|skipped)|error:|\*\* TEST" "$LOG" | grep -vE "passed" | tail -40
grep -cE "Test Case .* passed" "$LOG" | sed 's/^/passed: /'
exit $status
