import CoreMedia
import Foundation
import XCTest
@testable import ZenithMedia

/// A slow decoder must not hold up the pipeline: reading (feed), audio and
/// the buffering decisions keep running while it chews through frames.
@MainActor
final class SlowDecodeHandoffTests: XCTestCase {
    let decodeDelay = 0.15
    let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 8,
                              reconnectDelays: [0.05, 0.1], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)

    /// The real decoder (VideoToolbox), with each decode call made slow.
    func makeController() -> PlayerController {
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: { _ in false })
        c.useDecoders { track in
            let d = try VideoDecoder(track: track)
            d.decodeDelay = 0.15
            return d
        }
        return c
    }

    func testSlowDecoderDoesNotHoldUpDelivery() async throws {
        let d = try Fixtures.data("streams/orf1.ts")
        let c = makeController()
        c.play { PCRPacedSource(data: d) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok, "phase \(c.phase)")
        try await Task.sleep(for: .seconds(3))
        let s = c.stats
        
        XCTAssertGreaterThan(s.maxDecodeCall, decodeDelay * 0.8, "the decoder really is slow")
        XCTAssertGreaterThan(s.framesEnqueued, 10, "frames reach the renderer")
        XCTAssertNotNil(s.audioTrack, "audio selected")
        XCTAssertLessThan(s.maxFeedSeconds, 0.1, "feeding is not held up by the decoder")
        XCTAssertLessThan(s.maxDemuxFeed, 0.05, "demuxing is not held up by the decoder")
        XCTAssertEqual(s.rebuffers, 0, "the cushion covers the slow decoder (\(s.lastPauseInfo ?? ""))")
        XCTAssertEqual(c.phase, .playing)
        c.stop()
    }

    func waitFor(_ c: PlayerController, timeout: Double = 10, _ pred: (PlayerPhase) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if pred(c.phase) { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
}

