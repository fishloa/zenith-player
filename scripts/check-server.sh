#!/bin/bash
# Quick server check from the app's side: playlist as TS, guide header, one stream's first bytes.
# usage: scripts/check-server.sh [channel-id=tf-1]
set -euo pipefail
. "$(dirname "$0")/env.sh"
BASE="${ZENITH_URL:?set ZENITH_URL (see .env.example)}"
CH="${1:-tf-1}"
PL="$(curl -sf --max-time 15 "$BASE/playlist.m3u?format=ts")"
echo "playlist: $(grep -c '^#EXTINF' <<<"$PL") channels; header: $(head -1 <<<"$PL" | cut -c1-80)"
URL="$(grep -A1 "tvg-id=\"$CH\"" <<<"$PL" | tail -1)"
BYTES="$(curl -s --max-time 6 "$URL" | head -c 2000000 | wc -c | tr -d " " || true)"
echo "stream $CH: $BYTES bytes in 6 s from $URL"
[ "$BYTES" -gt 500000 ]
