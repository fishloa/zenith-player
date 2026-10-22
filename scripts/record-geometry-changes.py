#!/usr/bin/env python3
"""Record live channels and cut a fixture whenever the video geometry changes.

Watches each channel's TS stream, probes the newest ~2 s with ffprobe for the
stream SAR and the per-frame AFD (Active Format Description side data), and on
a change writes a raw, 188-aligned capture holding PRE seconds before and POST
seconds after the change, plus a .txt with what changed. Fixtures for the
rust-broadcast display-geometry work (16:9<->4:3 switches, AFD-only 4:3).

usage: scripts/record-geometry-changes.py <out-dir> [hours=12] [channel ...]
"""
import collections
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

BASE = os.environ["ZENITH_URL"].rstrip("/") + "/stream/ts/"
DEFAULT = ["rai-storia", "rai-scuola", "rai-premium", "krone", "stimmungsgarten"]
PRE, POST, PROBE_EVERY, PROBE_SPAN = 12.0, 12.0, 2.0, 2.5


def probe(data):
    """(sar, afd values seen) for a TS snippet, or None if ffprobe saw no video."""
    with tempfile.NamedTemporaryFile(suffix=".ts") as f:
        f.write(data)
        f.flush()
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=sample_aspect_ratio,width,height:frame=side_data_list",
             "-show_frames", "-of", "json", f.name],
            capture_output=True, text=True, timeout=30)
    try:
        j = json.loads(r.stdout or "{}")
    except ValueError:
        return None
    st = (j.get("streams") or [{}])[0]
    if not st.get("width") or not st.get("height") or st.get("sample_aspect_ratio") in (None, "?"):
        return None   # nothing decodable yet (reconnect, server restart)
    sar = f'{st.get("sample_aspect_ratio", "?")} {st["width"]}x{st["height"]}'
    afd = set()
    for fr in j.get("frames", []):
        for sd in fr.get("side_data_list", []):
            if "active_format" in sd or "Active format" in sd.get("side_data_type", ""):
                afd.add(str(sd.get("active_format", "?")))
    return sar, ",".join(sorted(afd)) or "-"


def watch(ch, out, deadline):
    ring = collections.deque()   # (arrival time, bytes), 188-aligned in total
    ring_bytes, last_probe, state, cut_at, cut_note = 0, 0.0, None, None, ""
    pending = b""
    while time.time() < deadline:
        try:
            resp = urllib.request.urlopen(BASE + ch, timeout=15)
            pending = b""
            while time.time() < deadline:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                now = time.time()
                pending += chunk
                if not ring and pending:
                    i = pending.find(b"\x47")
                    pending = pending[i:] if i >= 0 else b""
                n = len(pending) - len(pending) % 188
                if n:
                    ring.append((now, pending[:n]))
                    ring_bytes += n
                    pending = pending[n:]
                keep = PRE + POST + PROBE_SPAN + 5
                while ring and ring[0][0] < now - keep:
                    ring_bytes -= len(ring.popleft()[1])
                if cut_at and now >= cut_at + POST:
                    name = f"{ch}-{time.strftime('%Y%m%d-%H%M%S', time.localtime(cut_at))}"
                    data = b"".join(b for t, b in ring if t >= cut_at - PRE)
                    with open(os.path.join(out, name + ".raw.ts"), "wb") as f:
                        f.write(data)
                    with open(os.path.join(out, name + ".txt"), "w") as f:
                        f.write(f"channel {ch}\nchange at +{PRE:.0f}s (wall {time.ctime(cut_at)})\n{cut_note}\n"
                                f"bytes {len(data)}\nsource {BASE + ch}\n")
                    print(f"CUT {name}.raw.ts {cut_note}", flush=True)
                    cut_at = None
                if now - last_probe >= PROBE_EVERY:
                    last_probe = now
                    snip = b"".join(b for t, b in ring if t >= now - PROBE_SPAN)
                    p = probe(snip) if snip else None
                    if p and p != state:
                        if state is not None and cut_at is None:
                            cut_at, cut_note = now - PROBE_SPAN / 2, f"{state} -> {p}"
                            print(f"CHANGE {ch} {cut_note}", flush=True)
                        state = p
                        print(f"STATE {ch} sar={p[0]} afd={p[1]}", flush=True)
        except Exception as e:  # reconnect on any stream error
            print(f"RECONNECT {ch} {e}", flush=True)
            time.sleep(3)


def main():
    out = sys.argv[1]
    hours = float(sys.argv[2]) if len(sys.argv) > 2 else 12
    chans = sys.argv[3:] or DEFAULT
    os.makedirs(out, exist_ok=True)
    deadline = time.time() + hours * 3600
    ts = [threading.Thread(target=watch, args=(c, out, deadline), daemon=True) for c in chans]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    print("DONE", flush=True)


if __name__ == "__main__":
    main()
