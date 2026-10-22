#!/bin/bash
# Dev-only oracle: ffmpeg's bwdif (field rate) on interlaced fixtures, as raw
# yuv420p, for DeinterlacerTests. ffmpeg is a CLI tool here; nothing links it.
# usage: scripts/make-deint-reference.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/testdata/deint"; mkdir -p "$OUT"
for id in rai-2 france-2; do
  ffmpeg -v error -y -i "$ROOT/testdata/streams/$id.ts" -map 0:v:0 -frames:v 40 \
    -vf "bwdif=mode=send_field:parity=tff:deint=all" -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$OUT/$id.bwdif.yuv"
done
ls -l "$OUT"

# Ground truth from progressive 50p channels: interlace 40 progressive frames
# into 20 TFF frames (top field from frame 2k, bottom from 2k+1), so a
# perfect deinterlacer reproduces the 40 originals exactly.
#   <id>.truth.yuv        40 progressive frames (yuv420p)
#   <id>.synth.yuv        20 interlaced frames built from them
#   <id>.synth.bwdif.yuv  ffmpeg bwdif output on the synthetic frames (benchmark)
for id in orf1 rai-news-24; do
  ffmpeg -v error -y -i "$ROOT/testdata/streams/$id.ts" -map 0:v:0 -frames:v 40 -fps_mode passthrough -pix_fmt yuv420p -f rawvideo "$OUT/$id.truth.yuv"
  ffmpeg -v error -y -f rawvideo -pix_fmt yuv420p -s 1280x720 -r 50 -i "$OUT/$id.truth.yuv" \
    -vf "tinterlace=mode=interleave_top" -pix_fmt yuv420p -f rawvideo "$OUT/$id.synth.yuv"
  ffmpeg -v error -y -f rawvideo -pix_fmt yuv420p -s 1280x720 -r 25 -i "$OUT/$id.synth.yuv" \
    -vf "bwdif=mode=send_field:parity=tff:deint=all" -pix_fmt yuv420p -f rawvideo "$OUT/$id.synth.bwdif.yuv"
done
ls -l "$OUT"
