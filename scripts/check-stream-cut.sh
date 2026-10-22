#!/bin/bash
# Regression check for tools/stream-cut (e.g. after a transmux bump): re-cut
# every raw capture at the random-access point recorded in the manifest and
# require the decoded video frames to match the stored reference md5s.
# ffmpeg is a dev-machine tool here only. usage: scripts/check-stream-cut.sh [secs=10]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECS="${1:-10}"
DIR="$ROOT/testdata/streams"
CUT="$ROOT/tools/stream-cut/target/release/stream-cut"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/tools/stream-cut" && cargo build --release -q) || { echo "stream-cut build failed" >&2; exit 1; }
pass=0; fail=0
while IFS=$'\t' read -r id _ _ _ _ start; do
  rap=$(echo "$start" | grep -oE 'rap#[0-9]+' | tr -dc 0-9)
  [ -f "$DIR/$id.raw.ts" ] && [ -n "$rap" ] || continue
  "$CUT" "$DIR/$id.raw.ts" "$TMP/$id.ts" --seconds "$SECS" --rap "$rap" > /dev/null 2>&1 || { echo "FAIL $id: cut error"; fail=$((fail+1)); continue; }
  ffmpeg -nostdin -v quiet -threads 1 -i "$TMP/$id.ts" -map 0:v:0 -pix_fmt yuv420p -f framemd5 - | grep -v '^#' | awk -F', *' '{print $6}' > "$TMP/$id.md5"
  if cmp -s "$TMP/$id.md5" "$DIR/$id.md5"; then pass=$((pass+1)); else
    echo "FAIL $id: frames $(wc -l < "$TMP/$id.md5" | tr -d ' ') vs $(wc -l < "$DIR/$id.md5" | tr -d ' ') reference, $(diff "$TMP/$id.md5" "$DIR/$id.md5" | grep -c '^[<>]') lines differ"
    fail=$((fail+1)); fi
done < "$DIR/manifest.tsv"
# Damaged input must be rejected (transmux 0.27 resynchronises and reports it
# in Media::degraded instead of failing the demux).
python3 -I - "$DIR/orf1.raw.ts" "$TMP/badsync.ts" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
n = len(d) // 188
for i in range(n // 3, n // 3 + 400, 7):
    d[i * 188] = 0  # break sync bytes mid-stream
open(sys.argv[2], "wb").write(d)
PY
if "$CUT" "$TMP/badsync.ts" "$TMP/badsync.cut.ts" --seconds "$SECS" > /dev/null 2>&1; then
  echo "FAIL damaged capture was accepted"; fail=$((fail+1))   # SyncLoss since transmux 0.27.1
else pass=$((pass+1)); fi
# Continuity damage on a kept A/V PID must be rejected too (transmux 0.27.2
# Media::degraded_at carries the PID; damage on unused data PIDs is not fatal).
python3 -I - "$DIR/orf1.raw.ts" "$TMP/badcc.ts" <<'PY'
import sys
d = bytearray(open(sys.argv[1], "rb").read())
pids = {}
for i in range(0, len(d) - 187, 188):
    pid = ((d[i + 1] & 0x1F) << 8) | d[i + 2]
    pids[pid] = pids.get(pid, 0) + 1
video = max((p for p in pids if p not in (0, 0x1FFF)), key=pids.get)   # busiest PID = video
n, hit = len(d) // 188, 0
for k in range(n // 3, n):
    i = k * 188
    if ((d[i + 1] & 0x1F) << 8) | d[i + 2] == video and d[i + 3] & 0x10:
        d[i + 3] = (d[i + 3] & 0xF0) | ((d[i + 3] + 5) & 0x0F)   # skip 4 counter values
        hit += 1
        if hit == 20: break
open(sys.argv[2], "wb").write(d)
PY
if "$CUT" "$TMP/badcc.ts" "$TMP/badcc.cut.ts" --seconds "$SECS" > /dev/null 2>&1; then
  echo "FAIL continuity damage on the video PID was accepted"; fail=$((fail+1))
else pass=$((pass+1)); fi
echo "stream-cut regression: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
