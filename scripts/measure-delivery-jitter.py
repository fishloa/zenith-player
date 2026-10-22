#!/usr/bin/env python3
"""Measure how far a live TS stream's delivery lags its own clock.

Reads a channel for N seconds, timestamps every received chunk, and tracks the
PCR of the first PCR-carrying PID. For each PCR, lateness = arrival time minus
the time the PCR says it should have arrived (aligned so the earliest packet is
on time). The max lateness is the start buffer a player needs to never starve
on that run.

usage: scripts/measure-delivery-jitter.py <channel-id|url> [seconds=60]
"""
import os
import sys
import time
import urllib.request

BASE = os.environ["ZENITH_URL"].rstrip("/") + "/stream/ts/"


def main():
    src = sys.argv[1]
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    url = src if src.startswith("http") else BASE + src
    resp = urllib.request.urlopen(url, timeout=10)
    t0 = time.monotonic()
    buf = b""
    pcr_pid = None
    samples = []  # (arrival seconds, pcr seconds)
    total = 0
    while time.monotonic() - t0 < secs:
        chunk = resp.read1(65536)
        if not chunk:
            break
        now = time.monotonic() - t0
        total += len(chunk)
        buf += chunk
        # resync on 0x47
        while len(buf) >= 188:
            if buf[0] != 0x47:
                i = buf.find(b"\x47")
                buf = buf[i:] if i >= 0 else b""
                continue
            p, buf = buf[:188], buf[188:]
            pid = ((p[1] & 0x1F) << 8) | p[2]
            afc = (p[3] >> 4) & 3
            if afc in (2, 3) and p[4] >= 7 and p[5] & 0x10:
                if pcr_pid is None:
                    pcr_pid = pid
                if pid == pcr_pid:
                    base = (p[6] << 25) | (p[7] << 17) | (p[8] << 9) | (p[9] << 1) | (p[10] >> 7)
                    samples.append((now, base / 90000.0))
    if len(samples) < 2:
        print(f"{src}: no PCR seen ({total} bytes)")
        return
    # unwrap 33-bit PCR
    out, prev, off = [], None, 0.0
    for a, p in samples:
        if prev is not None and p + off < prev - 1000:
            off += (1 << 33) / 90000.0
        prev = p + off
        out.append((a, p + off))
    p0 = out[0][1]
    # offset so the earliest-relative packet is "on time"
    lead = min(a - (p - p0) for a, p in out)
    late = [a - (p - p0) - lead for a, p in out]
    media = out[-1][1] - p0
    wall = out[-1][0]
    print(f"{src}: wall={wall:.1f}s media={media:.1f}s rate={media / wall:.3f} "
          f"first_byte_burst={out[0][0]:.2f}s max_lateness={max(late):.2f}s "
          f"p99={sorted(late)[int(len(late) * 0.99)]:.2f}s bytes={total}")


if __name__ == "__main__":
    main()
