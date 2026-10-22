#!/bin/bash
# Capture clean, validated test streams from the Zenith server for decoder work.
#
# Per channel:
#   1. grab SECS+20 s of raw TS
#   2. tools/stream-cut: cut so video opens on a random-access point
#      (strict IDR when the channel sends them; else SPS + I + recovery-point
#      SEI, with leading pictures dropped) and keep SECS seconds
#   3. validate against an ffmpeg reference decode (dev machine only — no
#      ffmpeg code ships in the app):
#        - the source has zero decode errors across the cut window
#          (rejects reception glitches)
#        - every frame of the cut decodes bit-identical to the same frame
#          decoded with full prior context (proves the cut is self-contained)
#      on failure try the next RAP; after 8 RAPs, recapture (3 attempts)
#   4. store in testdata/streams/:
#        <id>.ts    trimmed TS, video + all audio
#        <id>.h264|.hevc   Annex B video elementary stream
#        <id>.md5   ffmpeg per-frame MD5 of yuv420p output (reference)
#        <id>.raw.ts  the unedited server capture (PAT/PMT repeated as live; for
#                     mid-stream join tests — the cut .ts carries PSI only once)
#        manifest.tsv
#
# usage: scripts/capture-test-streams.sh [seconds=10] [channel-id ...]
set -uo pipefail

. "$(dirname "$0")/env.sh"
BASE="${ZENITH_URL:?set ZENITH_URL to your Zenith server (see .env.example)}"
SECS="${1:-10}"; shift || true
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/testdata/streams"
CUT="$ROOT/tools/stream-cut/target/release/stream-cut"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

(cd "$ROOT/tools/stream-cut" && cargo build --release -q) || { echo "stream-cut build failed" >&2; exit 1; }

if [ $# -gt 0 ]; then
  CHANS=("$@")
else
  CHANS=($(curl -fsS "$BASE/playlist.m3u" | grep -oE '/stream/ts/[^[:space:]]+' | sed 's#/stream/ts/##'))
fi

# frame md5 list "<pts> <md5>" for the first video stream
fmd5() { ffmpeg -v quiet -i "$1" -map 0:v:0 -pix_fmt yuv420p -f framemd5 - | grep -v '^#' | awk -F', *' '{print $3, $6}'; }

capture_one() {
  local id="$1"
  local raw="$TMP/$id.raw.ts" ts="$TMP/$id.cut.ts" why=""
  for attempt in 1 2 3; do
    curl -s -m $((SECS + 20)) "$BASE/stream/ts/$id" -o "$raw"
    [ -s "$raw" ] || { why="empty capture"; continue; }
    fmd5 "$raw" > "$TMP/$id.full.md5"

    for rap in 0 1 2 3 4 5 6 7; do
      "$CUT" "$raw" "$ts" --seconds "$SECS" --rap "$rap" > "$TMP/$id.cut.json" 2>/dev/null \
        || { why="$(cat "$TMP/$id.cut.json")"; break; }

      # In-context errors inside the cut window = broken source; cut errors
      # that the frame comparison proves harmless (open-GOP MMCO warnings)
      # are tolerated.
      fmd5 "$ts" > "$TMP/$id.cut.md5"
      local n bad
      n=$(wc -l < "$TMP/$id.cut.md5" | tr -d ' ')
      bad=$(awk 'NR==FNR{h[$2]=1;next} !($2 in h)' "$TMP/$id.full.md5" "$TMP/$id.cut.md5" | wc -l | tr -d ' ')
      local src_errs
      src_errs=$(ffmpeg -v error -i "$ts" -map 0:v:0 -map '0:a?' -f null - 2>&1 \
                 | grep -vE "mmco: unref short failure|Last message repeated|number of reference frames .* exceeds max" | grep -c .)
      if [ "$n" -gt 0 ] && [ "$bad" -eq 0 ] && [ "$src_errs" -eq 0 ]; then
        local ext
        ext=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["video"])' "$TMP/$id.cut.json")
        cp "$ts" "$OUT/$id.ts"
        cp "$raw" "$OUT/$id.raw.ts"
        ffmpeg -v quiet -y -i "$ts" -map 0:v:0 -c copy -f "$ext" "$OUT/$id.$ext"
        awk '{print $2}' "$TMP/$id.cut.md5" > "$OUT/$id.md5"
        local v a start
        v=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,field_order -of csv=p=0 "$ts" | head -1)
        a=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$ts" | grep . | sort -u | paste -sd+ -)
        start=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["start"], "rap#%d" % d["rap_index"], "leading_dropped=%d" % d["leading_dropped"])' "$TMP/$id.cut.json")
        printf "%s\t%s\t%s\t%s\tframes=%s\t%s\n" "$id" "$ext" "$v" "${a:-none}" "$n" "$start"
        return 0
      fi
      why="rap#$rap: frames=$n mismatched=$bad source_errors=$src_errs"
    done
    echo "$id: attempt $attempt failed ($why)" >&2
  done
  rm -f "$OUT/$id".{ts,raw.ts,h264,hevc,md5}
  echo "$id: FAILED ($why)" >&2
  return 1
}
export -f capture_one fmd5
export BASE SECS OUT TMP CUT

printf "%s\n" "${CHANS[@]}" | xargs -P 6 -I{} bash -c 'capture_one "$@"' _ {} > "$TMP/manifest.tsv"
# Merge with any previous manifest (re-running for a subset keeps the rest).
if [ -f "$OUT/manifest.tsv" ]; then
  awk -F'\t' 'NR==FNR{new[$1]=1;next} !($1 in new)' "$TMP/manifest.tsv" "$OUT/manifest.tsv" > "$TMP/old.tsv"
  cat "$TMP/old.tsv" >> "$TMP/manifest.tsv"
fi
sort "$TMP/manifest.tsv" > "$OUT/manifest.tsv"
echo "== $(wc -l < "$TMP/manifest.tsv" | tr -d ' ') rows in manifest; this run: ${#CHANS[@]} requested → $OUT"
column -t -s $'\t' "$OUT/manifest.tsv"
