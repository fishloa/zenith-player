#!/bin/bash
# Demo channels for App Review and first-time users: 90 s excerpts of the
# Blender open movies (CC BY 3.0) plus a generated test pattern, as MPEG-TS,
# with a playlist pointing at where they are hosted.
# usage: scripts/make-demo-channels.sh <src-dir> <out-dir> <base-url>
#   src-dir: big_buck_bunny_1080p_h264.mov, Sintel.2010.1080p.mkv, tears_of_steel_1080p.mov
set -euo pipefail
SRC="$1"; OUT="$2"; BASE="${3%/}"
mkdir -p "$OUT"
enc() { # name source start
  ffmpeg -hide_banner -loglevel error -y -ss "$3" -t 90 -i "$2" \
    -map 0:v:0 -map 0:a:0 -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=25,format=yuv420p" \
    -c:v libx264 -profile:v high -preset slow -b:v 4M -maxrate 4M -bufsize 4M -g 50 -keyint_min 50 -sc_threshold 0 \
    -c:a aac -b:a 128k -ac 2 -ar 48000 \
    -f mpegts -mpegts_service_id 1 -metadata service_name="$1" "$OUT/$1.ts"
}
enc big-buck-bunny "$SRC/big_buck_bunny_1080p_h264.mov" 60
enc sintel "$SRC/Sintel.2010.1080p.mkv" 150
enc tears-of-steel "$SRC/tears_of_steel_1080p.mov" 120
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 60 -af volume=0.1 -c:v libx264 -profile:v high -b:v 2M -g 50 -pix_fmt yuv420p -c:a aac -b:a 96k -ac 2 \
  -f mpegts "$OUT/test-pattern.ts"
{
  echo '#EXTM3U'
  ch() { echo "#EXTINF:-1 tvg-id=\"$1\" tvg-name=\"$2\" group-title=\"$3\",$2"; echo "$BASE/$1.ts"; }
  ch big-buck-bunny "Big Buck Bunny" "Open Movies"
  ch sintel "Sintel" "Open Movies"
  ch tears-of-steel "Tears of Steel" "Open Movies"
  ch test-pattern "Test Pattern" "Test"
} > "$OUT/playlist.m3u"
ls -la "$OUT"
