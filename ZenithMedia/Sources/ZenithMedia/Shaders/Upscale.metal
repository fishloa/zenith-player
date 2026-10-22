#include <metal_stdlib>
using namespace metal;

// A frame's Y'CbCr to the RGB the MetalFX spatial scaler works on, then the
// scaled RGB back to the frame's Y'CbCr. The conversion is the ordinary video
// YUV<->RGB matrix swap in display-referred (nonlinear) colour, so luma
// round-trips exactly through the scaler's perceptual processing. Colour is
// carried in attachments (BT.601 / BT.709, transfer, full/video range) so the
// display layer reads the output exactly as it read the input.

// c0 = (matrix: 0 BT.601, 1 BT.709, transfer: 0 BT.601, 1 BT.709, 2 sRGB,
//       3 PQ, 4 HLG, input full range: 0 video, 1 full, output full range)
struct UpscaleParams { uint4 c0; };

// A frame's Y'CbCr (nonlinear, display-referred) and the RGB spatial scaling
// works on are the same nonlinear signal; the matrix conversion below is the
// ordinary video YUV<->RGB swap with no transfer applied, so luma round-trips
// exactly. MetalFX scales the display-referred (perceptual) colour.

// Video-range Y'CbCr to video RGB (rec.601 / rec.709 matrix, no transfer).
static float3 fromYCbCr(float y, float cb, float cr, uint matrix, bool full) {
    float yy, cbn, crn;
    if (full) {
        yy = y;
        cbn = (cb * 255.0 - 128.0) / 224.0;
        crn = (cr * 255.0 - 128.0) / 224.0;
    } else {
        yy = (y * 255.0 - 16.0) / 219.0;
        cbn = (cb * 255.0 - 128.0) / 224.0;
        crn = (cr * 255.0 - 128.0) / 224.0;
    }
    return matrix == 1
        ? float3(yy + 1.5748 * crn, yy - 0.187324 * cbn - 0.468124 * crn, yy + 1.8556 * cbn)
        : float3(yy + 1.402 * crn, yy - 0.344136 * cbn - 0.714136 * crn, yy + 1.772 * cbn);
}

// Video RGB to Y'CbCr (rec.601 / rec.709 matrix, no transfer).
static float3 toYCbCr(float3 rgb, uint matrix, bool full) {
    float y = dot(rgb, matrix == 1 ? float3(0.2126, 0.7152, 0.0722) : float3(0.299, 0.587, 0.114));
    float2 cbcr = matrix == 1
        ? float2((rgb.z - y) / 1.8556, (rgb.x - y) / 1.5748)
        : float2((rgb.z - y) / 1.772, (rgb.x - y) / 1.402);
    if (full) {
        y = clamp(y, 0.0, 1.0);
        cbcr = clamp(cbcr * 0.5 + 0.5, 0.0, 1.0);
    } else {
        y = clamp((219.0 * y + 16.0) / 255.0, 16.0 / 255.0, 235.0 / 255.0);
        cbcr = clamp((224.0 * cbcr + 128.0) / 255.0, 16.0 / 255.0, 240.0 / 255.0);
    }
    return float3(y, cbcr);
}

// 0: input Y'CbCr (luma plane, chroma plane) -> the scaler's colour texture,
// at the output size. Each output texel samples the source with bilinear
// weights: luma from its plane, chroma from the half-res plane (spreading the
// 2x2 chroma samples over the frame).
kernel void upscaleConvert(texture2d<float, access::sample> luma  [[texture(0)]],
                           texture2d<float, access::sample> chroma [[texture(1)]],
                           texture2d<float, access::write> dst     [[texture(2)]],
                           constant UpscaleParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = (float2(gid) + 0.5) / float2(size);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float y = luma.sample(s, uv).r;
    float2 cbcr = chroma.sample(s, uv).rg;
    float3 rgb = fromYCbCr(y, cbcr.x, cbcr.y, p.c0.x, p.c0.z == 1);
    dst.write(float4(rgb, 1.0), gid);
}

// 1: the scaled picture -> the output frame's luma plane.
kernel void upscaleStore(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant UpscaleParams &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float3 rgb = src.read(gid).rgb;
    dst.write(float4(toYCbCr(rgb, p.c0.x, p.c0.w == 1).r, 0, 0, 1), gid);
}

// 2: the scaled picture -> the output frame's interleaved CbCr plane (2x2 box).
kernel void upscaleChroma(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant UpscaleParams &p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint2 size = uint2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    uint2 at = gid * 2;
    uint2 sz = uint2(src.get_width(), src.get_height());
    float3 rgb;
    if (at.x + 1 >= sz.x || at.y + 1 >= sz.y) {
        rgb = src.read(uint2(min(at.x, sz.x - 1), min(at.y, sz.y - 1))).rgb;
    } else {
        float4 a = src.read(at), b = src.read(at + uint2(1, 0));
        float4 c = src.read(at + uint2(0, 1)), d = src.read(at + uint2(1, 1));
        rgb = (a + b + c + d).rgb * 0.25;
    }
    float3 ycc = toYCbCr(rgb, p.c0.x, p.c0.w == 1);
    dst.write(float4(ycc.y, ycc.z, 0, 1), gid);
}
