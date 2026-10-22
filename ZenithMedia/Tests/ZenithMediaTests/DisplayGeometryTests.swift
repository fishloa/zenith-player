import CoreMedia
import CoreVideo
import XCTest
@testable import ZenithMedia

/// transmux display geometry reaching the player: per-track colour
/// (0.27.6 video_signal) and in-stream shape changes (0.27.7 DisplayChanged),
/// on real captures.
final class DisplayGeometryTests: XCTestCase {
    private func videoTrack(_ ev: [DemuxEvent]) throws -> TrackInfo {
        try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 || $0.codec == .hevc })
    }

    /// melodie signals BT.470 B/G (primaries/transfer/matrix 5/5/5), limited range.
    func testTrackCarriesSignalledColour() throws {
        let c = try XCTUnwrap(try videoTrack(Fixtures.events("streams/melodie.ts")).colour, "melodie signals its colour")
        XCTAssertEqual(c.primaries, 5)
        XCTAssertEqual(c.transfer, 5)
        XCTAssertEqual(c.matrix, 5)
        XCTAssertFalse(c.fullRange)
    }

    /// Decoded frames are tagged so the display converts them correctly:
    /// matrix 5 (BT.470 B/G) is the BT.601 matrix.
    func testDecodedFramesCarryColourAttachments() throws {
        let ev = try Fixtures.events("streams/melodie.ts")
        let t = try videoTrack(ev)
        let dec = try VideoDecoder(track: t)
        var frames: [DecodedFrame] = []
        let lock = NSLock()
        dec.onFrames = { f in lock.lock(); frames += f; lock.unlock() }
        for s in Fixtures.samples(ev, track: t.trackID).prefix(30) { dec.decode(s) }
        let tail = dec.flush()
        lock.lock(); frames += tail; let all = frames; lock.unlock()
        let pb = try XCTUnwrap(all.first?.pixelBuffer)
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        XCTAssertEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
    }

    /// Unsignalled colour falls back by resolution: HD is BT.709, SD BT.601.
    func testUnsignalledColourFallsBackByResolution() throws {
        XCTAssertEqual(VideoColour.fallback(height: 1080).matrix, 1)
        XCTAssertEqual(VideoColour.fallback(height: 720).matrix, 1)
        XCTAssertEqual(VideoColour.fallback(height: 576).matrix, 5)
    }

    /// krone cut from the programme (SAR 16:11) to a slate (64:45): the demuxer
    /// announces it right before the first affected sample, with that sample's PTS.
    func testDisplayChangedArrivesBeforeTheFirstAffectedSample() throws {
        let ev = try Fixtures.events("streams/geometry/krone-20261018-175659.raw.ts")
        let t = try videoTrack(ev)
        var announced: (pts: Int64, par: PixelAspect?)?
        var checked = false
        for e in ev {
            if case .displayChanged(let track, let pts, let par, _) = e, track == t.trackID, par == PixelAspect(64, 45) {
                announced = (pts, par)
            } else if case .sample(let s) = e, s.trackID == t.trackID, let a = announced, !checked {
                XCTAssertEqual(s.pts, a.pts, "the event carries the first affected picture's PTS")
                checked = true
            }
        }
        XCTAssertNotNil(announced, "a DisplayChanged to 64:45 was emitted")
        XCTAssertTrue(checked, "a video sample followed the event")
    }

    /// The player reshapes from the announced picture: after the switch the
    /// renderer shows frames at the slate's pixel aspect, without waiting for a
    /// track update.
    @MainActor
    func testPlayerFollowsDisplayChanged() async throws {
        let d = try Fixtures.data("streams/geometry/krone-20261018-175659.raw.ts")
        let r = Renderer(audioOutput: false)
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 30,
                                  reconnectDelays: [0.05, 0.1], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: r, policy: policy, isInterlaced: PlayerController.codedInterlaced)
        c.play { PCRPacedSource(data: d) }
        let end = Date().addingTimeInterval(30)
        var sawSlate = false
        while Date() < end {
            if PixelAspectTests.par(r.displayedFormat) == PixelAspect(64, 45) { sawSlate = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        c.stop()
        XCTAssertTrue(sawSlate, "the renderer shows the 64:45 slate after the switch")
    }
}
