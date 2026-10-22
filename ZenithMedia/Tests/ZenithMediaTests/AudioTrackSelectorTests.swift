import XCTest
@testable import ZenithMedia

final class AudioTrackSelectorTests: XCTestCase {
    func audioTracks(_ id: String) throws -> [TrackInfo] {
        Fixtures.tracks(try Fixtures.events("streams/\(id).ts")).filter { [.aac, .ac3, .eac3, .mpegAudio].contains($0.codec) }
    }

    func testNeverPicksAccessibilityTracksAcrossAllCaptures() throws {
        let manifest = String(decoding: try Fixtures.data("streams/manifest.tsv"), as: UTF8.self)
        let ids = manifest.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
        XCTAssertEqual(ids.count, 43)
        for id in ids {
            let tracks = try audioTracks(id)
            let pick = try XCTUnwrap(AudioTrackSelector.choose(tracks), id)
            print("PICK \(id): \(pick.codec) \(pick.channels)ch \(pick.language) \(pick.role) \(pick.bitrate / 1000)k of \(tracks.count)")
            if tracks.contains(where: { $0.role != .audioDescription && $0.role != .hearingImpaired }) {
                XCTAssertNotEqual(pick.role, .audioDescription, id)
                XCTAssertNotEqual(pick.role, .hearingImpaired, id)
            }
        }
    }

    func testPrefersMultichannelOverStereoListedFirst() throws {
        for id in ["servustv", "orf1"] {   // ServusTV lists MP2 stereo first, AC-3 5.1 last
            let pick = try XCTUnwrap(AudioTrackSelector.choose(try audioTracks(id)))
            XCTAssertEqual(pick.codec, .ac3, id)
            XCTAssertEqual(pick.channels, 6, id)
        }
    }

    func testAllExcludedFallsBackToFirst() {
        let ad = TrackInfo(trackID: 7, codec: .mpegAudio, timescale: 48000, width: 0, height: 0, channels: 2,
                           sampleRate: 48000, pid: 100, config: Data(), descriptors: Data(), language: "qad", role: .audioDescription)
        XCTAssertEqual(AudioTrackSelector.choose([ad])?.trackID, 7)
        XCTAssertNil(AudioTrackSelector.choose([]))
    }
}
