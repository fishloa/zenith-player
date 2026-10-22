#!/usr/bin/env python3
"""Log delivery gaps of a live TS channel with wall-clock times.

Pairs with the Apple TV soak's arrival traces: run both on the same channel at
the same time; gaps seen by both clients at the same instant come from the
server, gaps seen by one only come from that client's path.

usage: scripts/measure-gaps-wallclock.py <channel-id> [seconds=600] [min_gap_ms=300]
"""
import os
import sys
import time
import urllib.request

ch = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 600
min_gap = (float(sys.argv[3]) if len(sys.argv) > 3 else 300) / 1000
resp = urllib.request.urlopen(os.environ["ZENITH_URL"].rstrip("/") + f"/stream/ts/{ch}", timeout=15)
start = time.time()
last = None          # gaps are measured from the first byte on (start-up isn't a gap)
n = total = 0
gaps = []
while time.time() - start < secs:
    chunk = resp.read1(65536)
    if not chunk:
        print(f"{ch}: stream ended after {time.time() - start:.1f} s")
        break
    now = time.time()
    if last is None:
        print(f"{ch}: first byte after {now - start:.3f} s", flush=True)
        last = now
    if now - last >= min_gap:
        gaps.append((last, now - last))
        print(f"GAP {ch} at {time.strftime('%H:%M:%S', time.localtime(last))}.{int((last % 1) * 1000):03d} length {now - last:.3f} s", flush=True)
    last = now
    n += 1
    total += len(chunk)
print(f"{ch}: {secs:.0f} s, {n} chunks, {total} bytes, {len(gaps)} gaps >= {min_gap * 1000:.0f} ms")
