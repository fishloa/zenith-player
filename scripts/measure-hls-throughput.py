#!/usr/bin/env python3
"""Measure unpaced throughput on the stream path (catch-up headroom).

zenithd serves HLS segments of a channel as static, unpaced files through
the same nginx chain as /stream/ts. Downloads every segment listed in the
playlist back-to-back on one keep-alive connection and reports bytes / time,
plus the segments' media rate for comparison.

usage: scripts/measure-hls-throughput.py <channel-id> [rounds=3]
"""
import http.client
import os
import re
import sys
import time
import urllib.parse
from urllib.parse import urlparse

HOST = urllib.parse.urlsplit(os.environ["ZENITH_URL"]).hostname


def main():
    ch = sys.argv[1]
    rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    conn = http.client.HTTPSConnection(HOST, timeout=20)
    seen = set()
    tot_b = tot_t = tot_media = 0.0
    for _ in range(rounds):
        conn.request("GET", f"/stream/hls/ts/{ch}/index.m3u8")
        pl = conn.getresponse().read().decode()
        segs = re.findall(r"#EXTINF:([0-9.]+),\s*\n(\S+)", pl)
        for dur, url in segs:
            if url in seen:
                continue
            seen.add(url)
            t0 = time.monotonic()
            conn.request("GET", urlparse(url).path)
            body = conn.getresponse().read()
            dt = time.monotonic() - t0
            tot_b += len(body)
            tot_t += dt
            tot_media += float(dur)
        if rounds > 1:
            time.sleep(4)
    if tot_t == 0:
        print(f"{ch}: no segments")
        return
    rate = tot_b * 8 / tot_t / 1e6
    media = tot_b * 8 / tot_media / 1e6 if tot_media else 0
    print(f"{ch}: segments={len(seen)} bytes={int(tot_b)} download_s={tot_t:.2f} "
          f"throughput={rate:.1f} Mbit/s media_rate={media:.1f} Mbit/s headroom={rate / media if media else 0:.1f}x")


if __name__ == "__main__":
    main()
