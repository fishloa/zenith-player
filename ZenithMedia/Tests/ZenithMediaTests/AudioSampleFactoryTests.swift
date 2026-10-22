import AudioToolbox
import CoreMedia
import XCTest
@testable import ZenithMedia

final class AudioSampleFactoryTests: XCTestCase {
    func testEveryCarriedCodecMakesBuffers() throws {
        let ev = try Fixtures.events("audio/mux-aligned.ts")
        for t in Fixtures.tracks(ev) {
            let f = try AudioSampleFactory(track: t)
            let samples = Fixtures.samples(ev, track: t.trackID)
            let sb = try XCTUnwrap(f.make(samples[0]), "\(t.codec)")
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sb), CMTime(value: samples[0].pts, timescale: t.timescale))
            if t.codec == .mpegAudio {
                XCTAssertTrue(f.isDecodedInApp)
                XCTAssertEqual(CMSampleBufferGetNumSamples(sb), 1152)
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sb)!)!.pointee
                XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
            } else {
                XCTAssertFalse(f.isDecodedInApp)
                XCTAssertEqual(CMSampleBufferGetNumSamples(sb), 1, "one compressed packet")
                XCTAssertEqual(CMSampleBufferGetTotalSampleSize(sb), samples[0].data.count)
            }
        }
    }

    func testGarbageFrameReturnsNilNotCrash() throws {
        let t = try XCTUnwrap(Fixtures.tracks(Fixtures.events("audio/mux-aligned.ts")).first { $0.codec == .mpegAudio })
        let f = try AudioSampleFactory(track: t)
        XCTAssertNil(f.make(MediaSample(trackID: t.trackID, pts: 0, dts: 0, duration: 0, isSync: true, isRAP: true, data: Data(count: 64))))
    }
}
