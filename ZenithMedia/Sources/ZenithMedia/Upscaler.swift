import CoreMedia
import CoreVideo
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import VideoToolbox

/// Colour of a frame, from its attachments (or, failing those, from its size:
/// HD is BT.709, SD is BT.601), for its Y'CbCr conversion.
public struct FrameColor: Equatable {
    public enum Matrix: UInt32 { case bt601 = 0, bt709 = 1 }
    public enum Transfer: UInt32 {
        case bt601 = 0, bt709 = 1, sRGB = 2, pq = 3, hlg = 4
        public var isHDR: Bool { self == .pq || self == .hlg }
    }

    public var matrix: Matrix
    public var transfer: Transfer
    public var fullRange: Bool

    static let bt601 = "ITU_R_601_4", ituR601 = "ITU-R_BT.601", smpte170m = "SMPTE_170M"

    static func string(_ pb: CVPixelBuffer, _ key: CFString) -> String? {
        guard let a = CVBufferCopyAttachment(pb, key, nil), CFGetTypeID(a) == CFStringGetTypeID() else { return nil }
        return a as? String
    }

    static func of(_ pb: CVPixelBuffer, width: Int, height: Int, fmt: OSType) -> FrameColor {
        var m: Matrix = width >= 1280 ? .bt709 : .bt601
        var t: Transfer = m == .bt709 ? .bt709 : .bt601
        if let s = string(pb, kCVImageBufferYCbCrMatrixKey) {
            if s == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String { m = .bt709 }
            else if s == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { m = .bt601 }
        }
        if let s = string(pb, kCVImageBufferTransferFunctionKey) {
            if s == kCVImageBufferTransferFunction_sRGB as String { t = .sRGB }
            else if s == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String { t = .pq }
            else if s == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String { t = .hlg }
            else if s == kCVImageBufferTransferFunction_ITU_R_709_2 as String || s == kCVImageBufferTransferFunction_SMPTE_240M_1995 as String { t = .bt709 }
            else if s == Self.bt601 || s == Self.ituR601 || s == Self.smpte170m { t = .bt601 }
        }
        let full = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || (CVBufferCopyAttachment(pb, "FullRangeVideo" as CFString, nil) as? NSNumber)?.boolValue == true
        return FrameColor(matrix: m, transfer: t, fullRange: full)
    }

    /// Attachments that make the display layer read our buffer the way we made it.
    public var attachments: [CFString: CFString] {
        var a: [CFString: CFString] = [:]
        a[kCVImageBufferYCbCrMatrixKey] = matrix == .bt709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
        a[kCVImageBufferColorPrimariesKey] = matrix == .bt709 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C
        a[kCVImageBufferTransferFunctionKey] = switch transfer {
        case .bt709: kCVImageBufferTransferFunction_ITU_R_709_2
        case .bt601: Self.bt601 as CFString
        case .sRGB: kCVImageBufferTransferFunction_sRGB
        case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
        return a
    }
}

/// MetalFX spatial scaling of decoded SD/HD frames to the screen's resolution.
///
/// A frame's planes become Metal textures through a Core Video texture cache
/// (zero-copy, the same path Deinterlacer uses), are converted to the RGB the
/// spatial scaler works on, scaled, and written back as a square-pixel `420f`
/// IOSurface buffer at the largest size of the frame's display aspect that
/// fits the target, tagged with the input's colour so the display layer shows
/// it exactly as it showed the original.
///
/// Threading: one queue, one command buffer per frame; the command buffer
/// completes before returning so the frame and its textures are safe to reuse.
/// Scalers, textures and buffer pools are reused: nothing is allocated per
/// frame once the sizes settle.
#if canImport(MetalFX)
public final class Upscaler: @unchecked Sendable {
    public private(set) var lastGPUTime: CFTimeInterval = 0
    /// Frames left to the display layer because they could not be prepared.
    public private(set) var failedFrames = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let convertFn: MTLComputePipelineState
    private let storeFn: MTLComputePipelineState
    private let chromaFn: MTLComputePipelineState
    private var scalers: [Key: Scaler] = [:]
    private var pools: [Size: BufferPool] = [:]

    struct UpscalerError: Error {}

    private struct Key: Hashable { let w: Int, h: Int, outW: Int, outH: Int }
    private struct Size: Hashable { let w: Int, h: Int }

    /// A spatial scaler plus its output-sized colour texture. The colour
    /// texture is allocated once per size and reused.
    private final class Scaler {
        let scaler: MTLFXSpatialScaler
        init?(_ key: Key, device: MTLDevice) {
            let d = MTLFXSpatialScalerDescriptor()
            d.inputWidth = key.w
            d.inputHeight = key.h
            d.outputWidth = key.outW
            d.outputHeight = key.outH
            d.colorTextureFormat = .rgba16Float
            d.outputTextureFormat = .rgba16Float
            d.colorProcessingMode = .perceptual
            guard let s = d.makeSpatialScaler(device: device) else { return nil }
            scaler = s
        }
    }

    /// One IOSurface buffer pool per output size. Always full range: it keeps
    /// 8 bits of precision at both ends, and the buffer is tagged with the
    /// input's colour so the display layer reads it as before.
    private final class BufferPool {
        let pool: CVPixelBufferPool
        init?(outW: Int, outH: Int) {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferWidthKey: outW, kCVPixelBufferHeightKey: outH,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferBytesPerRowAlignmentKey: 64,
            ]
            let aux: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, aux as CFDictionary, attrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { return nil }
            self.pool = pool
        }
    }

    private struct Params { var c0: SIMD4<UInt32> }

    /// nil when MetalFX spatial scaling is not available on this device.
    public init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              MTLFXSpatialScalerDescriptor.supportsDevice(device),
              let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        guard let lib = try? device.makeDefaultLibrary(bundle: Bundle.module),
              let convert = lib.makeFunction(name: "upscaleConvert"),
              let store = lib.makeFunction(name: "upscaleStore"),
              let chroma = lib.makeFunction(name: "upscaleChroma"),
              let convertPSO = try? device.makeComputePipelineState(function: convert),
              let storePSO = try? device.makeComputePipelineState(function: store),
              let chromaPSO = try? device.makeComputePipelineState(function: chroma) else { return nil }
        self.device = device
        self.queue = queue
        self.cache = cache
        convertFn = convertPSO; storeFn = storePSO; chromaFn = chromaPSO
    }

    // MARK: frame checks

    /// 10-bit / HDR frames are shown as decoded: this path is 8-bit SDR.
    static func isHighBitDepth(_ fmt: OSType, color: FrameColor) -> Bool {
        switch fmt {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
            return true
        default: return color.transfer.isHDR
        }
    }

    /// Native or larger, whichever way the screen is held: nothing to gain.
    static func isBigEnough(width w: Int, height h: Int, for target: CGSize) -> Bool {
        let tw = target.width, th = target.height
        return (Double(w) >= tw && Double(h) >= th) || (Double(w) >= th && Double(h) >= tw)
    }

    /// Largest square-pixel size of the display aspect that fits `bounds`.
    static func outputSize(width w: Int, height h: Int, pixelAspect: PixelAspect?, within bounds: CGSize) -> (Int, Int) {
        let aspect = (pixelAspect.map { Double($0.h) / Double($0.v) } ?? 1) * Double(w) / Double(h)
        let bw = Double(bounds.width), bh = Double(bounds.height)
        var ow = bw, oh = bw / aspect
        if oh > bh { oh = bh; ow = bh * aspect }
        return (max(2, Int(ow.rounded()) & ~1), max(2, Int(oh.rounded()) & ~1))
    }

    // MARK: upscale

    /// The frame at the screen size, or nil when there is nothing to gain
    /// (already big enough) or it must be shown as decoded (high bit depth,
    /// HDR, a pixel format this path cannot take).
    public func upscale(_ frame: DecodedFrame, pixelAspect: PixelAspect?, to bounds: CGSize) -> DecodedFrame? {
        let src = frame.pixelBuffer
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        guard bounds.width >= 2, bounds.height >= 2, sw > 0, sh > 0 else { return nil }
        let fmt = CVPixelBufferGetPixelFormatType(src)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        let color = FrameColor.of(src, width: sw, height: sh, fmt: fmt)
        guard !Self.isHighBitDepth(fmt, color: color) else { return nil }
        guard !Self.isBigEnough(width: sw, height: sh, for: bounds) else { return nil }
        let (ow, oh) = Self.outputSize(width: sw, height: sh, pixelAspect: pixelAspect, within: bounds)
        guard ow * oh > sw * sh else { return nil }

        guard let out = run(src, sw: sw, sh: sh, ow: ow, oh: oh, color: color) else {
            failedFrames += 1
            return nil
        }
        PixelAspect.attach(nil, to: out)
        for (k, v) in color.attachments {
            CVBufferSetAttachment(out, k, v, .shouldPropagate)
        }
        CVBufferSetAttachment(out, "FullRangeVideo" as CFString, kCFBooleanTrue, .shouldPropagate)
        return DecodedFrame(pixelBuffer: out, pts: frame.pts)
    }

    // MARK: processing

    private func run(_ src: CVPixelBuffer, sw: Int, sh: Int, ow: Int, oh: Int, color: FrameColor) -> CVPixelBuffer? {
        guard let scaler = scaler(for: Key(w: sw, h: sh, outW: ow, outH: oh)),
              let pool = pool(outW: ow, outH: oh),
              let out = makeBuffer(pool),
              let colorTexture = makeTexture(width: sw, height: sh),
              let scaled = makeTexture(width: ow, height: oh),
              let cmd = queue.makeCommandBuffer() else { return nil }

        // Input planes -> textures (zero-copy); keep the wrappers alive until
        // the command buffer completes so Core Video does not recycle them.
        var keep: [CVMetalTexture] = []
        guard let inLuma = texture(src, plane: 0, keep: &keep),
              let inChroma = texture(src, plane: 1, keep: &keep),
              let outLuma = texture(out, plane: 0, keep: &keep),
              let outChroma = texture(out, plane: 1, keep: &keep) else { return nil }

        var params = Params(c0: SIMD4(color.matrix.rawValue, color.transfer.rawValue, color.fullRange ? 1 : 0, 1))

        compute(convertFn, cmd: cmd, textures: [inLuma, inChroma, colorTexture], params: &params, size: (sw, sh))
        scaler.scaler.colorTexture = colorTexture
        scaler.scaler.outputTexture = scaled
        scaler.scaler.encode(commandBuffer: cmd)
        compute(storeFn, cmd: cmd, textures: [scaled, outLuma], params: &params, size: (ow, oh))
        compute(chromaFn, cmd: cmd, textures: [scaled, outChroma], params: &params, size: (ow / 2, oh / 2))

        cmd.commit()
        cmd.waitUntilCompleted()
        withExtendedLifetime(keep) {}
        CVMetalTextureCacheFlush(cache, 0)
        guard cmd.error == nil else { return nil }
        lastGPUTime = cmd.gpuEndTime - cmd.gpuStartTime
        return out
    }

    /// A frame plane (or output plane) as a Metal texture, zero-copy through
    /// the Core Video texture cache. The wrapper is kept in `keep` until the
    /// command buffer that uses it has completed.
    private func texture(_ pb: CVPixelBuffer, plane: Int, keep: inout [CVMetalTexture]) -> MTLTexture? {
        let fmt: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt,
            CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
        guard let t else { return nil }
        keep.append(t)
        return CVMetalTextureGetTexture(t)
    }

    private func compute<T>(_ fn: MTLComputePipelineState, cmd: MTLCommandBuffer, textures: [MTLTexture],
                            params: inout T, size: (Int, Int)) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(fn)
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        withUnsafeBytes(of: &params) { enc.setBytes($0.baseAddress!, length: MemoryLayout<T>.stride, index: 0) }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (size.0 + 15) / 16, height: (size.1 + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func scaler(for key: Key) -> Scaler? {
        if let s = scalers[key] { return s }
        guard let s = Scaler(key, device: device) else { return nil }
        if scalers.count >= 4 { scalers.removeAll(keepingCapacity: true) }
        scalers[key] = s
        return s
    }

    private func makeBuffer(_ pool: BufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool.pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    private func pool(outW: Int, outH: Int) -> BufferPool? {
        let key = Size(w: outW, h: outH)
        if let p = pools[key] { return p }
        guard let p = BufferPool(outW: outW, outH: outH) else { return nil }
        if pools.count >= 4 { pools.removeAll(keepingCapacity: true) }
        pools[key] = p
        return p
    }
}
#else
/// No MetalFX on this SDK (the tvOS simulator): upscaling is unavailable.
public final class Upscaler: @unchecked Sendable {
    public init?() { return nil }
    public func upscale(_ frame: DecodedFrame, pixelAspect: PixelAspect?, to bounds: CGSize) -> DecodedFrame? { nil }
}
#endif
