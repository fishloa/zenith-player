import CoreMedia
import CoreVideo
import Metal
import QuartzCore

public final class Deinterlacer {
    public private(set) var lastGPUTime: CFTimeInterval = 0
    /// Longest wall-clock wait for one field on the GPU (diagnostics).
    public private(set) var maxWaitSeconds: CFTimeInterval = 0
    public private(set) var maxGPUSeconds: CFTimeInterval = 0
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var window: [DecodedFrame] = []   // prev, cur, next
    private var lastTFF = true

    public struct InitError: Error {}

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { throw InitError() }
        let lib = try dev.makeDefaultLibrary(bundle: .module)
        guard let fn = lib.makeFunction(name: "deinterlace") else { throw InitError() }
        device = dev; queue = q
        pipeline = try dev.makeComputePipelineState(function: fn)
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
    }

    public func reset() { window.removeAll() }

    /// Push one decoded interlaced frame; returns the progressive frames now ready (0 or 2).
    public func push(_ f: DecodedFrame, topFieldFirst: Bool, fieldDuration: CMTime) -> [DecodedFrame] {
        lastTFF = topFieldFirst
        window.append(f)
        if window.count == 1 { window.insert(f, at: 0) }  // first frame: prev := cur
        guard window.count == 3 else { return [] }
        defer { window.removeFirst() }
        return render(prev: window[0], cur: window[1], next: window[2], tff: topFieldFirst, field: fieldDuration)
    }

    /// Emit the last held frame (next := cur) and reset.
    public func flush(fieldDuration: CMTime) -> [DecodedFrame] {
        defer { window.removeAll() }
        guard window.count == 2 else { return [] }
        return render(prev: window[0], cur: window[1], next: window[1], tff: lastTFF, field: fieldDuration)
    }

    private func render(prev: DecodedFrame, cur: DecodedFrame, next: DecodedFrame, tff: Bool, field: CMTime) -> [DecodedFrame] {
        let first: UInt32 = tff ? 0 : 1, second: UInt32 = 1 - first
        let a = run(cur: cur.pixelBuffer, p1: prev.pixelBuffer, n1: cur.pixelBuffer, p2: prev.pixelBuffer, n2: next.pixelBuffer, parity: first)
        let b = run(cur: cur.pixelBuffer, p1: cur.pixelBuffer, n1: next.pixelBuffer, p2: prev.pixelBuffer, n2: next.pixelBuffer, parity: second)
        var out: [DecodedFrame] = []
        if let a { out.append(DecodedFrame(pixelBuffer: a, pts: cur.pts)) }
        if let b { out.append(DecodedFrame(pixelBuffer: b, pts: cur.pts + field)) }
        return out
    }

    /// The CVMetalTexture must outlive the GPU work that uses its MTLTexture
    /// (Core Video recycles the backing otherwise), so callers keep it in
    /// `keep` until the command buffer has completed.
    private func texture(_ pb: CVPixelBuffer, plane: Int, keep: inout [CVMetalTexture]) -> MTLTexture? {
        guard let cache else { return nil }
        let fmt: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt,
            CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
        guard let t else { return nil }
        keep.append(t)
        return CVMetalTextureGetTexture(t)
    }

    private func outputBuffer(like pb: CVPixelBuffer) -> CVPixelBuffer? {
        let size = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        if pool == nil || poolSize != size {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: size.0, kCVPixelBufferHeightKey: size.1,
                kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = size
        }
        var out: CVPixelBuffer?
        guard let pool else { return nil }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        if let out { CVBufferPropagateAttachments(pb, out) }
        return out
    }

    private func run(cur: CVPixelBuffer, p1: CVPixelBuffer, n1: CVPixelBuffer, p2: CVPixelBuffer, n2: CVPixelBuffer, parity: UInt32) -> CVPixelBuffer? {
        guard let out = outputBuffer(like: cur), let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipeline)
        var prm = parity
        var keep: [CVMetalTexture] = []
        for plane in 0..<2 {
            let ins = [cur, p1, n1, p2, n2].map { texture($0, plane: plane, keep: &keep) }
            guard let o = texture(out, plane: plane, keep: &keep), ins.allSatisfy({ $0 != nil }) else { enc.endEncoding(); return nil }
            for (i, t) in ins.enumerated() { enc.setTexture(t, index: i) }
            enc.setTexture(o, index: 5)
            enc.setBytes(&prm, length: MemoryLayout<UInt32>.size, index: 0)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreadgroups(MTLSize(width: (o.width + 15) / 16, height: (o.height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        }
        enc.endEncoding()
        let t0 = CACurrentMediaTime()
        cmd.commit()
        cmd.waitUntilCompleted()
        maxWaitSeconds = max(maxWaitSeconds, CACurrentMediaTime() - t0)
        withExtendedLifetime(keep) {}
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        lastGPUTime = cmd.gpuEndTime - cmd.gpuStartTime
        maxGPUSeconds = max(maxGPUSeconds, lastGPUTime)
        return out
    }
}
