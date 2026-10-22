#!/usr/bin/env python3
"""Re-packetize the audio PES of an MPEG-2 TS so audio frames straddle PES
boundaries, the way some broadcasters' muxers do (Rai; rust-broadcast#1160).

Every audio PES gives its last TAIL bytes to the next PES on the same PID, so
each PES after the first starts with the tail of the previous PES's last
frame. PTS values are kept: a PES's PTS applies to the first access unit that
*starts* in it (ISO/IEC 13818-1 §2.4.3.7), which is unchanged, because the
moved bytes are a continuation, not a frame start.

PAT/PMT are copied; video and other PIDs pass through untouched.

usage: ts-misalign-audio-pes.py in.ts out.ts [tail_bytes=100]
"""
import sys

AUDIO_STREAM_IDS = range(0xC0, 0xE0)
PRIVATE_STREAM_1 = 0xBD  # AC-3 / E-AC-3 in DVB


def packets(data):
    for i in range(0, len(data) - 187, 188):
        p = data[i:i + 188]
        if p[0] == 0x47:
            yield p


def payload(p):
    afc = (p[3] >> 4) & 3
    if afc in (0, 2):
        return b""
    o = 4 + (1 + p[4] if afc == 3 else 0)
    return p[o:]


def split_pes(pes):
    """-> (header_bytes, payload_bytes)."""
    hlen = 9 + pes[8]
    return pes[:hlen], pes[hlen:]


def ts_packets(pid, pes, cc):
    out, off, first = [], 0, True
    while off < len(pes):
        room = 184
        take = min(room, len(pes) - off)
        pad = room - take
        hdr = bytes([0x47, (0x40 if first else 0) | (pid >> 8), pid & 0xFF])
        if pad:
            af = b"\x00" if pad == 1 else bytes([pad - 1, 0x00]) + b"\xff" * (pad - 2)
            if pad == 1:
                af = b"\x00"  # adaptation_field_length = 0
            pkt = hdr + bytes([0x30 | cc[pid]]) + af + pes[off:off + take]
        else:
            pkt = hdr + bytes([0x10 | cc[pid]]) + pes[off:off + take]
        assert len(pkt) == 188, len(pkt)
        cc[pid] = (cc[pid] + 1) & 0xF
        out.append(pkt)
        off += take
        first = False
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    tail = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    data = open(src, "rb").read()

    # Pass 1: reassemble PES per PID, remembering order and which PIDs are audio.
    order = []          # ("pkt", raw) | ("pes", pid, index)
    pes = {}            # pid -> list of bytearray
    cur = {}
    audio = set()
    for p in packets(data):
        pid = ((p[1] & 0x1F) << 8) | p[2]
        pusi = bool(p[1] & 0x40)
        pl = payload(p)
        if pusi and pl[:3] == b"\x00\x00\x01":
            sid = pl[3]
            if sid in AUDIO_STREAM_IDS or sid == PRIVATE_STREAM_1:
                audio.add(pid)
            if pid in audio:
                pes.setdefault(pid, []).append(bytearray(pl))
                order.append(("pes", pid, len(pes[pid]) - 1))
                cur[pid] = True
                continue
        if pid in audio and cur.get(pid):
            pes[pid][-1] += pl
            continue
        order.append(("pkt", p))

    # Pass 2: move the last `tail` bytes of each audio PES to the next one.
    moved = 0
    for pid, lst in pes.items():
        for i in range(len(lst) - 1):
            h, body = split_pes(bytes(lst[i]))
            nh, nbody = split_pes(bytes(lst[i + 1]))
            k = min(tail, len(body) - 1)
            lst[i] = bytearray(h + body[:-k])
            lst[i + 1] = bytearray(nh + body[-k:] + nbody)
            moved += 1
        for i, b in enumerate(lst):  # PES_packet_length must match the new size
            plen = len(b) - 6
            b[4:6] = (plen if plen <= 0xFFFF else 0).to_bytes(2, "big")

    cc = {pid: 0 for pid in pes}
    out = bytearray()
    for item in order:
        if item[0] == "pkt":
            out += item[1]
        else:
            _, pid, i = item
            for pkt in ts_packets(pid, bytes(pes[pid][i]), cc):
                out += pkt
    open(dst, "wb").write(out)
    print(f"{dst}: audio PIDs {sorted(audio)}, {moved} PES boundaries moved by {tail} bytes")


if __name__ == "__main__":
    main()
