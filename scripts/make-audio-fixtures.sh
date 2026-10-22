#!/bin/bash
# Build openly licensed audio test fixtures for every audio codec the player
# carries, from the Blender Foundation's "Sintel" masters hosted by Xiph.org.
#
# Licence of the source and of every derived file:
#   Sintel (c) copyright Blender Foundation | durian.blender.org
#   Creative Commons Attribution 3.0 (CC BY 3.0)
#   https://creativecommons.org/licenses/by/3.0/
#
# ffmpeg is used here as a command-line tool on the dev machine only, to cut,
# encode and mux the fixtures. No ffmpeg code is linked into or shipped with
# zenith-tv.
#
# Output: testdata/audio/
#   src-st.wav, src-51.wav       10 s source PCM (s16le, 48 kHz): stereo, 5.1
#   mp2-st.mp2, mp2-mono.mp2     MPEG-1 Layer II, 192 kbit/s stereo, 64 kbit/s mono
#   ac3-51.ac3                   AC-3 5.1, 448 kbit/s
#   eac3-51.eac3                 E-AC-3 5.1, 256 kbit/s
#   aac-st.adts                  AAC-LC stereo, 128 kbit/s, ADTS
#   <codec>.ref.wav              ffmpeg decode of each coded file (reference)
#   mux-aligned.ts               H.264-free TS, one audio PID per codec, default PES sizes
#   mux-split.ts                 same, every audio PES gives its last 100 bytes to the
#                                next, so frames straddle PES boundaries (rust-broadcast#1160)
#   ATTRIBUTION.txt
#
# usage: scripts/make-audio-fixtures.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/testdata/audio"
mkdir -p "$OUT"
BASE="https://media.xiph.org/sintel"
START=60   # seconds into the film: dialogue + music + effects
DUR=10
ff() { ffmpeg -v error -y -nostdin "$@"; }

# 10 s of source PCM, streamed from the FLAC masters (only the needed span is read)
ff -ss $START -t $DUR -i "$BASE/sintel-master-st.flac" -ar 48000 -c:a pcm_s16le "$OUT/src-st.wav"
ff -ss $START -t $DUR -i "$BASE/sintel-master-51.flac" -ar 48000 -c:a pcm_s16le "$OUT/src-51.wav"

ff -i "$OUT/src-st.wav" -c:a mp2 -b:a 192k "$OUT/mp2-st.mp2"
ff -i "$OUT/src-st.wav" -ac 1 -c:a mp2 -b:a 64k "$OUT/mp2-mono.mp2"
ff -i "$OUT/src-51.wav" -c:a ac3 -b:a 448k "$OUT/ac3-51.ac3"
ff -i "$OUT/src-51.wav" -c:a eac3 -b:a 256k "$OUT/eac3-51.eac3"
ff -i "$OUT/src-st.wav" -c:a aac -b:a 128k -f adts "$OUT/aac-st.adts"

for f in mp2-st.mp2 mp2-mono.mp2 ac3-51.ac3 eac3-51.eac3 aac-st.adts; do
  ff -i "$OUT/$f" -c:a pcm_s16le "$OUT/${f%.*}.ref.wav"
done

# One TS, one audio PID per codec, each with an ISO 639 language tag.
mux() {
  ff -i "$OUT/mp2-st.mp2" -i "$OUT/mp2-mono.mp2" -i "$OUT/ac3-51.ac3" -i "$OUT/eac3-51.eac3" -i "$OUT/aac-st.adts" \
     -map 0 -map 1 -map 2 -map 3 -map 4 -c copy \
     -metadata:s:a:0 language=eng -metadata:s:a:1 language=eng \
     -metadata:s:a:2 language=eng -metadata:s:a:3 language=eng -metadata:s:a:4 language=eng \
     "$@"
}
mux -f mpegts "$OUT/mux-aligned.ts"
# ffmpeg never splits a frame across PES, so misalign them ourselves.
python3 -I "$ROOT/scripts/ts-misalign-audio-pes.py" "$OUT/mux-aligned.ts" "$OUT/mux-split.ts" 100

cat > "$OUT/ATTRIBUTION.txt" <<'EOF'
All files in this directory are derived from the soundtrack of "Sintel".
Sintel (c) copyright Blender Foundation | durian.blender.org
Licensed under Creative Commons Attribution 3.0: https://creativecommons.org/licenses/by/3.0/
Source masters: https://media.xiph.org/sintel/ (sintel-master-st.flac, sintel-master-51.flac),
10 s from 60 s. Encoded/muxed with the ffmpeg command-line tool (scripts/make-audio-fixtures.sh).
EOF

ls -l "$OUT"
for f in "$OUT"/*.mp2 "$OUT"/*.ac3 "$OUT"/*.eac3 "$OUT"/*.adts "$OUT"/*.ts; do
  printf "%-16s %s\n" "$(basename "$f")" \
    "$(ffprobe -v error -show_entries stream=codec_name,channels,sample_rate,bit_rate -of csv=p=0 "$f" | paste -sd' ' -)"
done
