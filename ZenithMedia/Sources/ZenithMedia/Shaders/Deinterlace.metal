#include <metal_stdlib>
using namespace metal;

// Motion-adaptive vertical-temporal deinterlacer, one plane per dispatch
// (luma r8 or chroma rg8: the same code runs on both components).
//
// Written for zenith-tv from published descriptions only:
// - Vertical-temporal interpolation: M. Weston, BBC, "Interpolating lines of
//   video signals", EP0266079 B1 / US4789893 (filed 1986, expired). Current
//   field taps on lines y±1, y±3 (+0.526, −0.026; sum 1); each adjacent
//   (opposite-parity) field taps lines y, y±2, y±4 (+0.170, −0.116, +0.031;
//   sum 0), so the adjacent fields add vertical detail and nothing at DC.
// - Motion / spatio-temporal limiting: the widely documented "temporal +
//   spatial interlacing check" structure (yadif class); the output is kept
//   within [d − diff, d + diff] around the temporal average d.
//
// Rows with (y & 1) == parity are the current field and are copied. For a
// missing row y:  C = current field (rows y±1, y±3); P/N = previous/next
// field of opposite parity (rows y, y±2, y±4); PP/NN = same-parity fields one
// frame away (rows y±1).

struct DeintParams { uint parity; };

static inline float4 rd(texture2d<float, access::read> t, int x, int y) {
    int w = int(t.get_width()), h = int(t.get_height());
    return t.read(uint2(clamp(x, 0, w - 1), clamp(y, 0, h - 1)));
}

// Nearest row of the given parity inside the plane (edge handling).
static inline int rowOf(int y, uint parity, int h) {
    int r = clamp(y, 0, h - 1);
    if (uint(r & 1) != parity) r += (r + 1 < h) ? 1 : -1;
    return r;
}

kernel void deinterlace(texture2d<float, access::read> cur [[texture(0)]],
                        texture2d<float, access::read> pf  [[texture(1)]],   // P: previous field, opposite parity
                        texture2d<float, access::read> nf  [[texture(2)]],   // N: next field, opposite parity
                        texture2d<float, access::read> ppf [[texture(3)]],   // PP: same parity, one frame earlier
                        texture2d<float, access::read> nnf [[texture(4)]],   // NN: same parity, one frame later
                        texture2d<float, access::write> out [[texture(5)]],
                        constant DeintParams& prm [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int w = int(out.get_width()), h = int(out.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    int x = int(gid.x), y = int(gid.y);
    if (uint(y & 1) == prm.parity) { out.write(cur.read(gid), gid); return; }

    uint op = 1 - prm.parity;                   // parity of the missing rows
    int ym1 = rowOf(y - 1, prm.parity, h), yp1 = rowOf(y + 1, prm.parity, h);
    int ym3 = rowOf(y - 3, prm.parity, h), yp3 = rowOf(y + 3, prm.parity, h);
    int ym2 = rowOf(y - 2, op, h), yp2 = rowOf(y + 2, op, h);
    int ym4 = rowOf(y - 4, op, h), yp4 = rowOf(y + 4, op, h);

    float4 c = rd(cur, x, ym1), e = rd(cur, x, yp1);
    float4 p0 = rd(pf, x, y), n0 = rd(nf, x, y);
    float4 d = 0.5 * (p0 + n0);                 // temporal average of the missing line

    // Temporal differences: across the missing line, and current field vs
    // the same-parity fields one frame back / forward.
    float4 td0 = abs(p0 - n0);
    float4 td1 = 0.5 * (abs(rd(ppf, x, ym1) - c) + abs(rd(ppf, x, yp1) - e));
    float4 td2 = 0.5 * (abs(rd(nnf, x, ym1) - c) + abs(rd(nnf, x, yp1) - e));
    float4 diff = max(max(0.5 * td0, td1), td2);

    // Spatio-temporal check: widen the allowed range where the vertical
    // profile through the temporal average is not monotone.
    float4 pm2 = rd(pf, x, ym2), pp2 = rd(pf, x, yp2), nm2 = rd(nf, x, ym2), np2 = rd(nf, x, yp2);
    float4 b = 0.5 * (pm2 + nm2), f = 0.5 * (pp2 + np2);
    float4 hi = max(max(d - e, d - c), min(b - c, f - e));
    float4 lo = min(min(d - e, d - c), max(b - c, f - e));
    diff = max(max(diff, lo), -hi);

    // Interpolation.
    float4 c3 = rd(cur, x, ym3), e3 = rd(cur, x, yp3);
    float4 interp;
    // Weston vertical-temporal filter where the field has vertical detail the
    // temporal path can't explain; plain spatial cubic elsewhere.
    float4 vt = 0.526 * (c + e) - 0.026 * (c3 + e3)
              + 0.170 * (p0 + n0)
              - 0.116 * (pm2 + pp2 + nm2 + np2)
              + 0.031 * (rd(pf, x, ym4) + rd(pf, x, yp4) + rd(nf, x, ym4) + rd(nf, x, yp4));
    float4 sp = (-c3 + 9.0 * (c + e) - e3) / 16.0;
    interp = select(sp, vt, abs(c - e) > td0);

    float4 v = clamp(interp, d - diff, d + diff);
    // Static: no temporal change at all -> exact weave of the temporal average.
    v = select(v, d, diff <= 0.5 / 255.0);
    out.write(clamp(v, 0.0, 1.0), gid);
}
