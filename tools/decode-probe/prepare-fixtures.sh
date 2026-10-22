#!/bin/bash
# Build probe fixtures from validated captures (testdata/streams, made by
# scripts/capture-test-streams.sh): remux each .ts to .mov (video + all audio,
# stream copy — AVAssetReader can't read TS) and copy the reference .md5.
# ffmpeg runs on the dev machine only; nothing from it ships.
# usage: tools/decode-probe/prepare-fixtures.sh [channel-id ...]  (default: representative set)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../testdata/streams"
DST="$HERE/Fixtures"
# one per category: PAFF HD, PAFF SD, MBAFF HD, mixed PAFF+MBAFF, MBAFF SD+AAC,
# progressive 720p (AC3+MP2), HEVC (MP2), French MBAFF+MP2
SET=("$@"); [ ${#SET[@]} -gt 0 ] || SET=(tf-1 melodie france-2 rai-2 rai-4 orf1 rai-news-24 france-3)
mkdir -p "$DST"
for id in "${SET[@]}"; do
  [ -f "$SRC/$id.ts" ] || { echo "skip $id (no capture)"; continue; }
  # hvc1 tag: VideoToolbox rejects hev1 (-12906); hvc1 carries VPS/SPS/PPS in hvcC.
  tag=(); [ -f "$SRC/$id.hevc" ] && tag=(-tag:v hvc1)
  ffmpeg -v error -y -i "$SRC/$id.ts" -map 0:v:0 -map '0:a?' -c copy ${tag[@]+"${tag[@]}"} -f mov "$DST/$id.mov"
  cp "$SRC/$id.md5" "$DST/$id.md5"
  cp "$SRC/$id.ts" "$DST/$id.ts"
  # Reference PCM (s16le, interleaved) for each MP2 track: tvOS has no MP2
  # decoder, so the probe checks a bundled one against ffmpeg's.
  n=0
  for codec in $(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$DST/$id.mov"); do
    [ "$codec" = mp2 ] && ffmpeg -v error -y -i "$DST/$id.mov" -map 0:a:$n -f s16le "$DST/$id.a$n.s16"
    n=$((n + 1))
  done
  echo "fixture $id: $(du -h "$DST/$id.mov" | cut -f1)"
done
cp "$SRC/manifest.tsv" "$DST/manifest.tsv"
