import CoreMedia
import Foundation
import VideoToolbox

public struct DecodedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let pts: CMTime
    public init(pixelBuffer: CVPixelBuffer, pts: CMTime) { self.pixelBuffer = pixelBuffer; self.pts = pts }
}

/// What the pipeline needs from a video decoder: `VideoDecoder` (VideoToolbox),
/// or a substitute through PlayerController's decoder factory (tests).
public protocol VideoDecoding: AnyObject {
    var onFrames: ([DecodedFrame]) -> Void { get set }
    /// A frame failed inside the decoder (asynchronous error); called on a decoder thread.
    var onError: (OSStatus) -> Void { get set }
    var usingHardware: Bool { get }
    @discardableResult func decode(_ sample: MediaSample) -> OSStatus
    func adopt(_ track: TrackInfo) -> Bool
    func invalidate()
}

/// VideoToolbox decode with PTS reordering. VT picks the decoder: hardware
/// for progressive streams; it refuses interlaced H.264 (-12911) and falls
/// back to its software decoder (probe finding), so no explicit mode is set.
public final class VideoDecoder: VideoDecoding {
    public var onFrames: ([DecodedFrame]) -> Void = { _ in }
    /// A frame failed inside VideoToolbox (asynchronous error). Called on a VT thread.
    public var onError: (OSStatus) -> Void = { _ in }
    public private(set) var errorCount = 0
    /// Read on every batch by the pipeline: never waits for a decode call in
    /// progress (try-lock) and never touches an invalidated session.
    public var usingHardware: Bool {
        guard sessionLock.try() else { return lastUsingHardware }
        defer { sessionLock.unlock() }
        guard !invalidated else { return lastUsingHardware }
        var v: CFBoolean?
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: nil, valueOut: &v)
        lastUsingHardware = v.map { CFBooleanGetValue($0) } ?? false
        return lastUsingHardware
    }
    private var lastUsingHardware = false

    private let session: VTDecompressionSession
    private var format: CMVideoFormatDescription
    private let timescale: Int32
    /// Pixel aspect of the parameter sets in use; frames are stamped with the
    /// value current when they were submitted, so a change applies from the
    /// first frame decoded under the new SPS.
    private var pixelAspect: PixelAspect?
    /// Colour for frames of the parameter sets in use; stamped at submit like
    /// the pixel aspect. A stream that signals none falls back by height.
    private var colour: VideoColour
    private var reorder = ReorderBuffer<CVPixelBuffer>(depth: 16)   // safety cap; normal release is by DTS
    private var dtsByPTS: [Int64: Int64] = [:]
    private var inFlightCount = 0
    private let lock = NSLock()
    /// Held across every call into the session, so the pipeline can't
    /// invalidate it while the decode worker is inside DecodeFrame (that
    /// crashed VideoToolbox). Separate from `lock`: output callbacks take
    /// `lock` and may run while a decode call is in progress.
    private let sessionLock = NSLock()
    private var invalidated = false
    /// Test seam: how long one `VTDecompressionSessionDecodeFrame` call takes.
    var decodeDelay: TimeInterval = 0

    public init(track: TrackInfo) throws {
        format = try FormatDescriptions.video(track)
        timescale = track.timescale
        pixelAspect = track.pixelAspect
        colour = track.colour ?? VideoColour.fallback(height: track.height)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard st == noErr, let s else { throw FormatError(status: st, what: "VTDecompressionSessionCreate") }
        session = s
        // Software decode (interlaced H.264 on Apple TV) must keep up with live:
        // ask for real-time priority and every core. Hints; ignored where unsupported.
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_ThreadCount,
                             value: ProcessInfo.processInfo.activeProcessorCount as CFNumber)
    }

    deinit { invalidate() }

    @discardableResult
    public func decode(_ sample: MediaSample) -> OSStatus {
        if decodeDelay > 0 { Thread.sleep(forTimeInterval: decodeDelay) }
        guard let sb = makeSampleBuffer(sample) else { return -1 }
        lock.lock()
        dtsByPTS[sample.pts] = sample.dts
        inFlightCount += 1
        let (par, col) = (pixelAspect, colour)
        lock.unlock()
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !invalidated else {
            lock.lock(); dtsByPTS[sample.pts] = nil; inFlightCount = max(0, inFlightCount - 1); lock.unlock()
            return kVTInvalidSessionErr
        }
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, image, pts, _ in
            guard let self else { return }
            self.lock.lock()
            self.inFlightCount = max(0, self.inFlightCount - 1)
            let dts = self.dtsByPTS.removeValue(forKey: pts.value)
            var out: [(Int64, CVPixelBuffer)] = []
            if status == noErr, let image {
                PixelAspect.attach(par, to: image)
                col.attach(to: image)
                out = self.reorder.push(pts: pts.value, image)
            } else { self.errorCount += 1 }
            if let dts { out += self.reorder.release(upTo: dts) }
            self.lock.unlock()
            if status != noErr { self.onError(status) }
            if !out.isEmpty { self.onFrames(out.map { DecodedFrame(pixelBuffer: $0.1, pts: CMTime(value: $0.0, timescale: self.timescale)) }) }
        }
        if status != noErr {
            // No callback will come.
            lock.lock(); dtsByPTS[sample.pts] = nil; inFlightCount = max(0, inFlightCount - 1); lock.unlock()
        }
        return status
    }

    /// Wait for in-flight frames and return everything still held, in PTS order.
    public func flush() -> [DecodedFrame] {
        sessionLock.lock()
        if !invalidated { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        sessionLock.unlock()
        lock.lock(); defer { lock.unlock() }
        return reorder.drain().map { DecodedFrame(pixelBuffer: $0.1, pts: CMTime(value: $0.0, timescale: timescale)) }
    }

    /// Switch to new parameter sets in place if VideoToolbox can decode them
    /// with this session (e.g. an extra PPS). Returns false if a new session
    /// is needed. The session is shared with the decode worker, which uses it
    /// for whatever it decodes next.
    public func adopt(_ track: TrackInfo) -> Bool {
        guard let fd = try? FormatDescriptions.video(track) else { return false }
        sessionLock.lock()
        let accepted = !invalidated && VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: fd)
        sessionLock.unlock()
        guard accepted else { return false }
        lock.lock()
        format = fd
        pixelAspect = track.pixelAspect
        colour = track.colour ?? VideoColour.fallback(height: track.height)
        lock.unlock()
        return true
    }

    /// Take a display geometry announced for the pictures from `pts` on
    /// (decode order): the next frames submitted get it. The caller submits
    /// samples in order, so this applies from the first affected picture.
    public func apply(pixelAspect: PixelAspect?, colour: VideoColour?) {
        lock.lock()
        self.pixelAspect = pixelAspect
        if let colour { self.colour = colour }
        lock.unlock()
    }

    var pendingDTSCount: Int { lock.lock(); defer { lock.unlock() }; return dtsByPTS.count }

    /// Samples submitted that have not been through the output callback yet
    /// (their frames are not delivered, or not for long).
    var inFlight: Int { lock.lock(); defer { lock.unlock() }; return inFlightCount }

    /// Block until every submitted frame has been through the output callback.
    func waitForPending() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if !invalidated { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    /// Safe from any queue: waits for a decode call in progress on another
    /// queue, and later calls return kVTInvalidSessionErr.
    public func invalidate() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        guard !invalidated else { return }
        invalidated = true
        VTDecompressionSessionInvalidate(session)
    }

    private func makeSampleBuffer(_ s: MediaSample) -> CMSampleBuffer? {
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: s.data.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: s.data.count, flags: 0, blockBufferOut: &bb) == noErr,
            let bb else { return nil }
        _ = s.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: s.data.count) }
        var timing = CMSampleTimingInfo(
            duration: s.duration > 0 ? CMTime(value: CMTimeValue(s.duration), timescale: timescale) : .invalid,
            presentationTimeStamp: CMTime(value: s.pts, timescale: timescale),
            decodeTimeStamp: CMTime(value: s.dts, timescale: timescale))
        var size = s.data.count
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sb)
        return sb
    }
}
