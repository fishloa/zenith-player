import CoreMedia
import CoreVideo
import XCTest
@testable import ZenithMedia

/// Anamorphic SD (720x576, SAR 64:45 or 16:11) must reach the display layer
/// with its pixel aspect, and a mid-stream SAR change (new SPS) must reshape
/// the picture from the first frame decoded under it.
final class PixelAspectTests: XCTestCase {
    static func par(_ fd: CMFormatDescription?) -> PixelAspect? {
        guard let fd, let d = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [CFString: Any],
              let h = d[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? Int,
              let v = d[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? Int else { return nil }
        return PixelAspect(h, v)
    }

    static func par(_ pb: CVPixelBuffer) -> PixelAspect? {
        guard let d = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Any],
              let h = d[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int,
              let v = d[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int else { return nil }
        return PixelAspect(h, v)
    }

    private func videoTrack(_ ev: [DemuxEvent]) throws -> TrackInfo {
        try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 || $0.codec == .hevc })
    }

    /// The demuxer reports the SPS VUI sample aspect ratio (transmux
    /// TrackSpec.display): real captures, Extended_SAR and Table E-1 idc 4.
    func testDemuxerReportsSampleAspectFromTheSPS() throws {
        XCTAssertEqual(try videoTrack(Fixtures.events("streams/melodie.ts")).pixelAspect, PixelAspect(64, 45))
        XCTAssertEqual(try videoTrack(Fixtures.events("streams/krone.ts")).pixelAspect, PixelAspect(16, 11))
        let hd = try videoTrack(Fixtures.events("streams/france-2.ts")).pixelAspect
        XCTAssertTrue(hd == nil || hd!.isSquare, "HD is square pixels, got \(String(describing: hd))")
        // Feeds the display: anamorphic SD gets the PixelAspectRatio extension.
        let t = try videoTrack(Fixtures.events("streams/melodie.ts"))
        XCTAssertEqual(Self.par(try FormatDescriptions.video(t)), PixelAspect(64, 45))
    }

    func testFormatDescriptionCarriesPixelAspect() throws {
        var t = try videoTrack(Fixtures.events("streams/melodie.ts"))
        t.pixelAspect = PixelAspect(64, 45)
        XCTAssertEqual(Self.par(try FormatDescriptions.video(t)), PixelAspect(64, 45))
        t.pixelAspect = nil
        XCTAssertNil(Self.par(try FormatDescriptions.video(t)))
    }

    func testSquarePixelsAddNoExtension() throws {
        var t = try videoTrack(Fixtures.events("streams/france-2.ts"))
        t.pixelAspect = PixelAspect(1, 1)
        XCTAssertNil(Self.par(try FormatDescriptions.video(t)))
    }

    func testDecodedFramesCarryPixelAspectAndFollowAChange() throws {
        let ev = try Fixtures.events("streams/krone.ts")
        var t = try videoTrack(ev)
        t.pixelAspect = PixelAspect(16, 11)
        let dec = try VideoDecoder(track: t)
        var frames: [DecodedFrame] = []
        let lock = NSLock()
        dec.onFrames = { f in lock.lock(); frames += f; lock.unlock() }
        let samples = Fixtures.samples(ev, track: t.trackID)
        // A new SPS takes effect at a random access point: split at the last one.
        let half = try XCTUnwrap(samples.indices.last { $0 > 0 && samples[$0].isRAP })
        for s in samples[..<half] { dec.decode(s) }
        dec.waitForPending()
        t.pixelAspect = PixelAspect(12, 11)   // a 4:3 programme follows
        XCTAssertTrue(dec.adopt(t))
        for s in samples[half...] { dec.decode(s) }
        let tail = dec.flush()
        lock.lock(); frames += tail; let all = frames; lock.unlock()
        XCTAssertFalse(all.isEmpty)
        let pars = all.map { Self.par($0.pixelBuffer) }
        XCTAssertTrue(pars.allSatisfy { $0 != nil }, "every frame carries its pixel aspect")
        XCTAssertEqual(pars.first!, PixelAspect(16, 11))
        XCTAssertEqual(pars.last!, PixelAspect(12, 11))
        // One switch, in order: no frame decoded after the change shows the old shape.
        let switches = zip(pars, pars.dropFirst()).filter { $0 != $1 }.count
        XCTAssertEqual(switches, 1)
    }

    func testRendererFormatFollowsPixelAspect() {
        func frame(_ i: Int, _ p: PixelAspect) -> DecodedFrame {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 720, 576, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
            PixelAspect.attach(p, to: pb!)
            return DecodedFrame(pixelBuffer: pb!, pts: CMTime(value: Int64(i), timescale: 25))
        }
        let r = Renderer(audioOutput: false)
        let s = r.beginSession()
        r.enqueueVideo(frame(0, PixelAspect(64, 45)), session: s)
        r.sync()
        XCTAssertEqual(Self.par(r.displayedFormat), PixelAspect(64, 45))
        r.enqueueVideo(frame(1, PixelAspect(16, 11)), session: s)
        r.sync()
        XCTAssertEqual(Self.par(r.displayedFormat), PixelAspect(16, 11))
    }
}
