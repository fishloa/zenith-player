import CoreMedia
import CoreVideo
import XCTest
@testable import ZenithMedia

final class RendererTests: XCTestCase {
    func frame(_ i: Int) -> DecodedFrame {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        return DecodedFrame(pixelBuffer: pb!, pts: CMTime(value: Int64(i), timescale: 50))
    }

    /// Review I3: enqueues from a session that has ended never reach the renderer.
    func testStaleSessionEnqueuesAreDropped() {
        let r = Renderer(audioOutput: false)
        let old = r.beginSession()
        r.enqueueVideo(frame(0), session: old)
        r.endSession()
        r.sync()
        let before = r.enqueuedVideo
        for i in 1...10 { r.enqueueVideo(frame(i), session: old) }
        r.sync()
        XCTAssertEqual(r.enqueuedVideo, before, "stale session leaked frames")
        let new = r.beginSession()
        r.enqueueVideo(frame(20), session: new)
        let end = Date().addingTimeInterval(2)
        repeat { r.sync() } while r.enqueuedVideo <= before && Date() < end
        XCTAssertGreaterThan(r.enqueuedVideo, before)
    }

    /// Review I6: a renderer that stops accepting data must not grow memory without bound.
    func testBacklogIsCapped() {
        let r = Renderer(audioOutput: false)
        let s = r.beginSession()
        for i in 0..<2000 { r.enqueueVideo(frame(i), session: s) }   // never started: layer queue fills
        r.sync()
        XCTAssertLessThanOrEqual(r.videoBacklogCount, Renderer.maxVideoBacklog)
    }

    /// Live stalls on the TV: status reads come from the pipeline (every audio
    /// sample) and the main actor (every monitor tick); they must not wait for
    /// the renderer queue, which can sit in a slow AVFoundation call.
    func testStatusReadsDoNotWaitForTheRendererQueue() {
        let r = Renderer(audioOutput: false)
        r.blockQueueForTesting(seconds: 1.0)
        let t0 = Date()
        _ = r.audioFailed
        _ = r.displayFailed
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.05)
        r.sync()
    }

    /// The clock must reflect start/pause/resume as soon as they are issued,
    /// even while the renderer queue is busy (on the TV an audio-renderer swap
    /// can hold it): a stale clock from the previous channel made the new one
    /// look starved right after its start.
    func testClockReflectsCommandsBeforeTheQueueRunsThem() {
        let r = Renderer(audioOutput: false)
        let s = r.beginSession()
        r.start(at: CMTime(seconds: 86000, preferredTimescale: 90000), session: s)
        r.sync()
        r.blockQueueForTesting(seconds: 0.5)
        r.start(at: CMTime(seconds: 300, preferredTimescale: 90000), session: s)
        XCTAssertEqual(CMTimeGetSeconds(r.currentTime), 300, accuracy: 0.1, "after start")
        r.pause(at: CMTime(seconds: 301, preferredTimescale: 90000), session: s)
        XCTAssertEqual(CMTimeGetSeconds(r.currentTime), 301, accuracy: 0.01, "after pause")
        r.resume(at: CMTime(seconds: 301, preferredTimescale: 90000), session: s)
        XCTAssertEqual(CMTimeGetSeconds(r.currentTime), 301, accuracy: 0.1, "after resume")
        r.sync()
        // Applied with plain setRate(_:time:) (the host-time variant broke audio
        // on the Apple TV), so it runs from the resume point as of when the
        // queue ran it: no extrapolation left over.
        XCTAssertEqual(CMTimeGetSeconds(r.currentTime), 301.0, accuracy: 0.2, "running from the resume point once applied")
    }
}
