import AudioToolbox
import CoreMedia
import XCTest
@testable import ZenithMedia

final class FormatDescriptionTests: XCTestCase {
    func testH264() throws {
        let t = try XCTUnwrap(Fixtures.tracks(Fixtures.events("streams/france-2.ts")).first { $0.codec == .h264 })
        let fd = try FormatDescriptions.video(t)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd), kCMVideoCodecType_H264)
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        XCTAssertEqual(d.width, 1920)
        XCTAssertEqual(d.height, 1080)
    }

    func testHEVC() throws {
        let t = try XCTUnwrap(Fixtures.tracks(Fixtures.events("streams/rai-news-24.ts")).first { $0.codec == .hevc })
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try FormatDescriptions.video(t)), kCMVideoCodecType_HEVC)
    }

    func testCompressedAudio() throws {
        let tracks = Fixtures.tracks(try Fixtures.events("audio/mux-aligned.ts"))
        for (codec, format, ch) in [(Codec.ac3, kAudioFormatAC3, 6), (.eac3, kAudioFormatEnhancedAC3, 6), (.aac, kAudioFormatMPEG4AAC, 2)] {
            let t = try XCTUnwrap(tracks.first { $0.codec == codec })
            let fd = try FormatDescriptions.audio(t)
            let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(fd)).pointee
            XCTAssertEqual(asbd.mFormatID, format, "\(codec)")
            XCTAssertEqual(Int(asbd.mChannelsPerFrame), ch, "\(codec)")
            XCTAssertEqual(asbd.mSampleRate, 48000, "\(codec)")
        }
    }

    func testLPCMWithLayout() throws {
        let fd = try FormatDescriptions.lpcm(channels: 6, sampleRate: 48000, labels: [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen])
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(fd)).pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mBytesPerFrame, 12)
        var size = 0
        XCTAssertNotNil(CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size))
    }

    func testMpegAudioTrackIsNotCompressedPassthrough() throws {
        let t = try XCTUnwrap(Fixtures.tracks(Fixtures.events("audio/mux-aligned.ts")).first { $0.codec == .mpegAudio })
        XCTAssertThrowsError(try FormatDescriptions.audio(t), "MP2 is decoded in-app, never passed compressed")
    }
}
