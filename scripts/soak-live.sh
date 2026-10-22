#!/bin/bash
# Live soak on the Apple TV: every channel of $ZENITH_URL/playlist.m3u
# through the real ZenithMedia pipeline for N seconds each (default 60).
# Pass = first frame <= 2.5 s, no buffering, no reconnects, no dropped frames,
# no audio underruns, an audio track selected, stop < 0.5 s.
# usage: scripts/soak-live.sh [seconds=60] [device-udid]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-60}"
DEV="${2:-}"
cd "$ROOT/tools/decode-probe"
# run-on-device.sh waits for "PROBE PLAYER DONE"; the soak prints "PROBE SOAK DONE"
WAIT_FOR="PROBE SOAK DONE" ./run-on-device.sh "$DEV" -soak "$SECS"
