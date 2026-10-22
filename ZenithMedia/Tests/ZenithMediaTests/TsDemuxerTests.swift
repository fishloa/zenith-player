import CoreAudioTypes
import XCTest
@testable import ZenithMedia

final class TsDemuxerTests: XCTestCase {
    func testFrance2ThroughSwift() throws {
        let ev = try Fixtures.events("streams/france-2.ts")
        let tracks = Fixtures.tracks(ev)
        let video = try XCTUnwrap(tracks.first { $0.codec == .h264 })
        XCTAssertEqual(video.width, 1920)
        XCTAssertEqual(video.timescale, 90000)
        XCTAssertEqual(Fixtures.samples(ev, track: video.trackID).count, try Fixtures.frames("france-2"))
        XCTAssertEqual(tracks.filter { $0.codec == .eac3 }.count, 3)
    }

    func testPayloadCopiedBeforeNextPoll() throws {
        // Data must be copied out of the Rust buffer: compare two samples after both polls.
        let d = TsDemuxer()
        d.feed(try Fixtures.data("audio/mux-aligned.ts"))
        d.finish()
        var firstTwo: [MediaSample] = []
        while let e = d.nextEvent(), firstTwo.count < 2 {
            if case .sample(let s) = e, s.trackID == 1 { firstTwo.append(s) }
        }
        XCTAssertEqual(firstTwo.count, 2)
        XCTAssertNotEqual(firstTwo[0].pts, firstTwo[1].pts)
        XCTAssertEqual(firstTwo[0].data.prefix(2), Data([0xFF, 0xFD]), "MPEG-1 Layer II sync")
    }

    func testMpaDecoderStereo() throws {
        let ev = try Fixtures.events("audio/mux-aligned.ts")
        let mp2 = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .mpegAudio })
        let dec = MpaDecoder()
        let frame = try XCTUnwrap(dec.decode(Fixtures.samples(ev, track: mp2.trackID)[0].data))
        XCTAssertEqual(frame.channels, 2)
        XCTAssertEqual(frame.sampleRate, 48000)
        XCTAssertEqual(frame.samples.count, 1152 * 2)
        XCTAssertEqual(frame.labels, [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
    }

    /// transmux 0.25.4 facts survive the C ABI (layout must match zenith_media.h).
    func testUpstreamFactsCrossTheABI() throws {
        let f2 = Fixtures.tracks(try Fixtures.events("streams/france-2.ts"))
        XCTAssertTrue(f2.contains { $0.codec == .eac3 && $0.role == .main && $0.language == "fre" })
        XCTAssertEqual(f2.filter { $0.role == .audioDescription }.count, 1)
        XCTAssertEqual(f2.first { $0.codec == .h264 }?.scan, .mbaff)
        let ev = try Fixtures.events("streams/tf-1.ts")
        let v = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 })
        XCTAssertEqual(v.scan, .paff)
        let s = Fixtures.samples(ev, track: v.trackID)
        XCTAssertTrue(s.allSatisfy { $0.fields == 2 && $0.bottomFieldFirst == false })
        XCTAssertEqual(s.first?.join, .joinPoint)
        let orf = Fixtures.tracks(try Fixtures.events("streams/orf1.ts"))
        XCTAssertEqual(orf.first { $0.codec == .ac3 }?.channels, 6)
        XCTAssertTrue(orf.contains { $0.role == .hearingImpaired })
    }
}
