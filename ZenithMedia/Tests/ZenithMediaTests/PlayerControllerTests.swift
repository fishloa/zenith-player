import CoreMedia
import XCTest
@testable import ZenithMedia

/// Feeds a fixed sequence of chunks / errors, for state-machine tests.
struct ScriptedSource: ByteSource {
    enum Step { case data(Data), fail(Error), hang, pause(Double) }
    let steps: [Step]
    func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                for s in steps {
                    switch s {
                    case .data(let d): cont.yield(d)
                    case .fail(let e): cont.finish(throwing: e); return
                    case .hang: try? await Task.sleep(for: .seconds(3600)); return
                    case .pause(let secs): try? await Task.sleep(for: .seconds(secs))
                    }
                    await Task.yield()
                }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}

@MainActor
final class PlayerControllerTests: XCTestCase {
    let fast = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 0.5,
                            reconnectDelays: [0.05, 0.1], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)

    func controller(interlaced: Bool = false) -> PlayerController {
        PlayerController(renderer: Renderer(audioOutput: false), policy: fast, isInterlaced: { _ in interlaced })
    }

    func waitFor(_ c: PlayerController, timeout: Double = 10, _ pred: (PlayerPhase) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if pred(c.phase) { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }

    func testPlaysProgressiveFixture() async throws {
        let c = controller()
        let data = try Fixtures.data("streams/orf1.ts")
        c.play { ScriptedSource(steps: [.data(data), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok, "phase \(c.phase)")
        XCTAssertNotNil(c.stats.audioTrack)
        c.stop()
    }

    /// Review Focus 2: join mid-GOP — first displayed frame is a RAP.
    func testStartsAtFirstRAP() async throws {
        let c = controller(interlaced: true)
        let data = try Fixtures.data("streams/tf-1.raw.ts")  // raw capture: PAT/PMT repeat, as live
        c.play { ScriptedSource(steps: [.data(data.subdata(in: 400_000..<data.count)), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        XCTAssertEqual(c.stats.framesDroppedBeforeRAP > 0, true, "leading non-RAP AUs were skipped")
        c.stop()
    }

    /// Review Focus 4: no usable audio — play video-only.
    func testVideoOnlyStartsPlaying() async throws {
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: fast, chooseAudio: { _ in nil }, isInterlaced: { _ in false })
        c.play { ScriptedSource(steps: [.data(try! Fixtures.data("streams/orf1.ts")), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        XCTAssertNil(c.stats.audioTrack)
        c.stop()
    }

    func testHTTPErrorReconnectsWithBackoff() async {
        let c = controller()
        c.play { ScriptedSource(steps: [.fail(ByteSourceError.http(503))]) }
        let first = await waitFor(c) { if case .reconnecting(1) = $0 { return true } else { return false } }
        let second = await waitFor(c) { if case .reconnecting(2) = $0 { return true } else { return false } }
        XCTAssertTrue(first && second)
        c.stop()
    }

    func testStallShowsBufferingThenReconnects() async throws {
        let c = controller()
        let data = try Fixtures.data("streams/orf1.ts")
        c.play { ScriptedSource(steps: [.data(data.prefix(4_000_000)), .hang]) }
        let playing = await waitFor(c) { $0 == .playing }
        let buffering = await waitFor(c) { if case .buffering = $0 { return true } else { return false } }
        let reconnecting = await waitFor(c) { if case .reconnecting = $0 { return true } else { return false } }
        XCTAssertTrue(playing && buffering && reconnecting)
        c.stop()
    }

    /// Review Focus 5: a PTS discontinuity restarts start-up without hanging.
    func testDiscontinuityRestartsStartup() async throws {
        let c = controller()
        let a = try Fixtures.data("streams/orf1.ts"), b = try Fixtures.data("streams/orf-2.ts")
        // The second capture comes after the first has started, as on a live
        // stream (instant bulk delivery lets live-buffer's start gate see the
        // jump before the first start, which is not a restart).
        c.play { ScriptedSource(steps: [.data(a), .pause(3), .data(b), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .seconds(4))
        XCTAssertGreaterThanOrEqual(c.stats.restarts, 1, "second capture's PTS jump triggered a restart")
        let still = await waitFor(c, timeout: 5) { $0 == .playing }
        XCTAssertTrue(still)
        c.stop()
    }

    /// Review Focus 3: after stop(), late callbacks from the old pipeline must not reach the renderer.
    func testStaleGenerationDropped() async throws {
        let c = controller()
        c.play { ScriptedSource(steps: [.data(try! Fixtures.data("streams/orf1.ts")), .hang]) }
        _ = await waitFor(c) { $0 == .playing }
        c.stop()
        c.renderer.sync()
        let before = c.renderer.enqueuedVideo
        try await Task.sleep(for: .milliseconds(500))
        c.renderer.sync()
        XCTAssertEqual(c.renderer.enqueuedVideo, before, "nothing reached the renderer after stop()")
        XCTAssertEqual(c.phase, .loading)
    }

    /// Audio-track discontinuities (gaps in one audio PID) must not restart video start-up.
    func testAudioDiscontinuityDoesNotRestartVideo() async throws {
        let c = controller(interlaced: false)
        let data = try Fixtures.data("streams/rai-news-24.ts")   // 32 audio-track discontinuities in 10 s
        c.play { ScriptedSource(steps: [.data(data), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok, "phase \(c.phase), droppedBeforeRAP \(c.stats.framesDroppedBeforeRAP)")
        XCTAssertEqual(c.stats.restarts, 0)
        c.stop()
    }

    /// Audio for the start PTS often arrives in the TS before the video RAP;
    /// it must be kept, so sound starts with the picture.
    func testAudioStartsWithVideo() async throws {
        for (id, il) in [("rai-2", true), ("orf1", false), ("rai-news-24", false)] {
            let c = controller(interlaced: il)
            let data = try Fixtures.data("streams/\(id).ts")
            c.play { ScriptedSource(steps: [.data(data), .hang]) }
            let ok = await waitFor(c) { $0 == .playing }
            XCTAssertTrue(ok, id)
            XCTAssertLessThanOrEqual(abs(c.stats.avOffset), 0.05, "\(id): first audio vs first video PTS")
            c.stop()
        }
    }

    /// A mid-stream parameter-set change (orf1: avcC 42 -> 43 bytes) must not
    /// restart playback or drop frames.
    func testConfigUpdateDoesNotRestart() async throws {
        let c = controller(interlaced: false)
        c.play { ScriptedSource(steps: [.data(try! Fixtures.data("streams/orf1.ts")), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(c.stats.restarts, 0)
        XCTAssertEqual(c.stats.framesDroppedBeforeRAP, 0)
        XCTAssertEqual(c.stats.framesDropped, 0)
        c.stop()
    }

    /// Review C1: after a backward PTS jump (encoder restart) playback resumes.
    func testBackwardPTSJumpResumes() async throws {
        let c = controller()
        let a = try Fixtures.data("streams/orf1.ts")
        c.play { ScriptedSource(steps: [.data(a), .pause(3), .data(a), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        let first = c.stats.framesEnqueued
        try await Task.sleep(for: .seconds(6))
        XCTAssertGreaterThanOrEqual(c.stats.restarts, 1)
        XCTAssertGreaterThan(c.stats.framesEnqueued, first + 20, "new timeline reached the renderer")
        XCTAssertEqual(c.phase, .playing)
        c.stop()
    }

    /// Review I1: a stream without a supported video track fails instead of loading forever.
    func testNoVideoTrackFails() async throws {
        let c = controller()
        c.play { ScriptedSource(steps: [.data(try! Fixtures.data("audio/mux-aligned.ts")), .hang]) }
        let failed = await waitFor(c, timeout: 8) { $0 == .failed }
        XCTAssertTrue(failed, "phase \(c.phase)")
        c.stop()
    }

    /// Review I2: a short gap in delivery rebuffers and resumes without reconnecting.
    func testRecoversFromDeliveryGapWithoutReconnect() async throws {
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 8,
                                  reconnectDelays: [0.05], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: { _ in false })
        let d = try Fixtures.data("streams/orf1.ts")
        // Live-paced (PCR) with a 4 s delivery gap 2.5 s in.
        c.play { PCRPacedSource(data: d, gapAt: 2.5, gap: 4) }
        let playing = await waitFor(c) { $0 == .playing }
        var sawBuffering = false, sawReconnect = false
        let end = Date().addingTimeInterval(9)
        while Date() < end {
            if case .buffering = c.phase { sawBuffering = true }
            if case .reconnecting = c.phase { sawReconnect = true }
            if sawBuffering, c.phase == .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(playing && sawBuffering, "buffered during the gap")
        XCTAssertFalse(sawReconnect, "no reconnect for a short gap")
        XCTAssertEqual(c.phase, .playing, "resumed after the gap")
        c.stop()
    }

    /// Review M3: a decoder that fails every frame asynchronously is broken:
    /// reconnect promptly instead of waiting out the stall timeout.
    func testPersistentAsyncDecodeErrorsReconnect() async throws {
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 30,
                                  reconnectDelays: [0.05], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: { _ in false })
        let d = try Fixtures.data("streams/orf1.ts")
        let part = (d.count / 3) / 188 * 188
        // Live-paced: garbling keeps the adaptation fields, so PCR pacing still works.
        c.play { PCRPacedSource(data: d.prefix(part) + Self.garbleSliceData(d.suffix(from: part))) }
        let playing = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(playing, "phase \(c.phase)")
        let reconnected = await waitFor(c, timeout: 6) { if case .reconnecting = $0 { return true }; return false }
        XCTAssertTrue(reconnected, "phase \(c.phase), dropped \(c.stats.framesDropped), decoded \(c.stats.framesDecoded), restarts \(c.stats.restarts), rebuffers \(c.stats.rebuffers)")
        XCTAssertGreaterThan(c.stats.framesDropped, 0, "async failures count as dropped frames")
        c.stop()
    }

    /// Keeps TS/PES framing and the first 32 bytes of each PES (NAL headers)
    /// intact, scrambles the rest of every payload: the decoder gets
    /// well-formed access units with garbage slice data.
    static func garbleSliceData(_ ts: Data) -> Data {
        var b = [UInt8](ts)
        var i = 0
        while i + 188 <= b.count {
            let pusi = b[i + 1] & 0x40 != 0
            let pid = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
            let afc = (b[i + 3] >> 4) & 3
            var off = 4
            if afc == 2 || afc == 3 { off += 1 + Int(b[i + 4]) }
            if pid > 0x1F, pid != 0x1FFF, afc & 1 == 1, off < 188 {
                let from = pusi ? min(188, off + 32) : off
                if from < 188 { for k in from..<188 { b[i + k] ^= UInt8(truncatingIfNeeded: 0x5A &+ k) } }
            }
            i += 188
        }
        return Data(b)
    }

    /// Device harness conditions: fixtures paced in real time (10 s files).
    /// Sound must start with the picture (≤ 40 ms) on MP2 and AC-3 channels.
    func testAudioStartsWithVideoWhenPaced() async throws {
        var report: [String] = []
        for (id, il) in [("france-3", true), ("melodie", true), ("rai-2", true), ("france-2", true)] {
            let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in il })
            let url = Fixtures.root.appendingPathComponent("streams/\(id).ts")
            let size = try Data(contentsOf: url).count
            c.play { FileByteSource(url: url, bytesPerSecond: size / 10) }
            let ok = await waitFor(c) { $0 == .playing }
            XCTAssertTrue(ok, id)
            report.append("\(id) av=\(c.stats.avOffset) audio=\(c.stats.audioTrackLabel ?? "none")")
            XCTAssertLessThanOrEqual(abs(c.stats.avOffset), 0.04, "\(id): \(c.stats.audioTrackLabel ?? "none")")
            c.stop()
        }
        print("PACED " + report.joined(separator: " | "))
    }

    /// After a re-buffer, sound must resume with the picture: audio already
    /// handed to the renderer before the stall is flushed with it.
    func testAudioResumesWithVideoAfterRebuffer() async throws {
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 8,
                                  reconnectDelays: [0.05], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        for id in ["france-3", "rai-2", "orf1"] {
            let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: { _ in id != "orf1" })
            let d = try Fixtures.data("streams/\(id).ts")
            c.play { PCRPacedSource(data: d, gapAt: 2.5, gap: 4) }   // live-paced, 4 s gap 2.5 s in
            var sawBuffering = false, resumed = false
            let end = Date().addingTimeInterval(12)
            while Date() < end {
                if case .buffering = c.phase { sawBuffering = true }
                if sawBuffering, c.phase == .playing { resumed = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(resumed, "\(id): re-buffered and resumed (phase \(c.phase))")
            XCTAssertLessThanOrEqual(abs(c.stats.avOffset), 0.04, "\(id): first audio vs first video PTS after the re-buffer")
            c.stop()
        }
    }

    /// Diagnostics for live stalls: a starvation is classified by whether
    /// network data had stopped (no chunk for > 0.25 s) or kept arriving.
    func testStarvationDuringDeliveryGapIsClassifiedNoData() async throws {
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 8,
                                  reconnectDelays: [0.05], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: { _ in false })
        let d = try Fixtures.data("streams/orf1.ts")
        // Live-paced (PCR) with a 4 s delivery gap 2.5 s in.
        c.play { PCRPacedSource(data: d, gapAt: 2.5, gap: 4) }
        var sawBuffering = false
        let end = Date().addingTimeInterval(12)
        while Date() < end {
            if case .buffering = c.phase { sawBuffering = true }
            if sawBuffering, c.phase == .playing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawBuffering)
        XCTAssertGreaterThanOrEqual(c.stats.starvedNoData, 1, "starved while no data arrived")
        XCTAssertEqual(c.stats.starvedWithData, 0)
        XCTAssertGreaterThan(c.stats.maxChunkGap, 3.0, "the 4 s delivery gap")
        c.stop()
    }

    /// Live join on the raw captures of the mono-AAC channels (on the TV their
    /// sound started 88-112 ms after the picture).
    func testAudioStartsWithVideoOnRawAACChannels() async throws {
        var report: [String] = []
        for id in ["rai-4", "rai-scuola", "rai-storia", "rai-premium"] {
            let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in true })
            let url = Fixtures.root.appendingPathComponent("streams/\(id).raw.ts")
            let size = try Data(contentsOf: url).count
            c.play { FileByteSource(url: url, bytesPerSecond: size / 30) }   // raw captures are ~30 s
            let ok = await waitFor(c) { $0 == .playing }
            XCTAssertTrue(ok, id)
            report.append("\(id) av=\(c.stats.avOffset) \(c.stats.audioTrackLabel ?? "none")")
            XCTAssertLessThanOrEqual(abs(c.stats.avOffset), 0.04, "\(id)")
            c.stop()
        }
        print("RAWAAC " + report.joined(separator: " | "))
    }

    /// Start-up breakdown for zap-time work: each milestone is recorded, in order.
    func testStartupMilestonesAreRecordedInOrder() async throws {
        let c = controller(interlaced: true)
        let url = Fixtures.root.appendingPathComponent("streams/tf-1.raw.ts")
        let size = try Data(contentsOf: url).count
        c.play { FileByteSource(url: url, bytesPerSecond: size / 30) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        let s = c.stats
        let steps = [s.firstByteAfter, s.firstTrackAfter, s.joinPointAfter, s.firstFrameAfter]
        XCTAssertTrue(steps.allSatisfy { $0 != nil }, "\(steps)")
        let v = steps.compactMap { $0 }
        XCTAssertEqual(v, v.sorted(), "byte <= track <= join <= frame: \(v)")
        c.stop()
    }

    /// A delivery gap pauses playback once; live-buffer decides the refill
    /// depth (its own tests cover the target), the player resumes and does
    /// not stall again on the steady data that follows.
    func testRebufferRefillsToLargerTarget() async throws {
        try await oneGapOneStall(gap: 1.5)   // the TV link's ~1.4 s stalls
    }

    /// A gap as long as live-buffer's track-silence timeout (3 s) still stalls
    /// once (rust-broadcast #1359: a global gap excludes no track).
    func testLongGapStallsOnce() async throws {
        try await oneGapOneStall(gap: 3)
    }

    private func oneGapOneStall(gap: Double) async throws {
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in true })
        let d = try Fixtures.data("streams/tf-1.raw.ts")      // ~30 s, live-paced, one gap at 4 s
        c.play { PCRPacedSource(data: d, gapAt: 4, gap: gap) }
        var sawBuffering = false, resumed = false
        let end = Date().addingTimeInterval(14)
        while Date() < end {
            if case .buffering = c.phase { sawBuffering = true }
            if sawBuffering, c.phase == .playing { resumed = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawBuffering)
        XCTAssertTrue(resumed, "resumed after the refill")
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(c.stats.rebuffers, 1, "one stall, no repeat: \(c.stats.lastPauseInfo ?? "")")
        c.stop()
    }

    /// A live stream that played and then ended cleanly (the server closed it:
    /// servustv on the Apple TV) reconnects at once, not after the back-off.
    func testCleanEndAfterPlayingReconnectsImmediately() async throws {
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 8,
                                  reconnectDelays: [2, 4], reconnectMax: 8, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: { _ in false })
        let d = try Fixtures.data("streams/orf1.ts")
        var opened: [Date] = []
        c.play {
            opened.append(Date())
            return opened.count == 1 ? ScriptedSource(steps: [.data(d), .pause(1.5)]) : ScriptedSource(steps: [.data(d), .hang])
        }
        let end = Date().addingTimeInterval(8)
        while Date() < end, opened.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(opened.count, 2, "reconnected")
        if opened.count == 2 {
            XCTAssertLessThan(opened[1].timeIntervalSince(opened[0]), 1.5 + 1.0, "no 2 s back-off after a clean end")
        }
        c.stop()
    }

    /// Buffering happens before the decoder: with 10 s of media delivered at
    /// once, decoded video stays within ~0.6 s of the clock (memory: decoded
    /// 1080 frames are ~3 MB each) while the compressed buffer holds the rest.
    func testDecodedVideoStaysNearTheClock() async throws {
        let c = controller()
        let d = try Fixtures.data("streams/orf1.ts")
        c.play { ScriptedSource(steps: [.data(d), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertGreaterThan(c.stats.bufferedSeconds, 4, "compressed media buffered")
        XCTAssertLessThan(c.stats.decodedAheadSeconds, PlayerPolicy().decodeAhead + 0.2,
                          "decoded stays within decodeAhead of the clock, not the whole compressed buffer")
        c.stop()
    }

    /// A stall pauses the clock and resumes it where it stopped: no renderer
    /// flush, no media skipped (the live-buffer Pause/Resume contract).
    func testStallPausesAndResumesWithoutFlush() async throws {
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 8,
                                  reconnectDelays: [0.05], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let r = Renderer(audioOutput: false)
        let c = PlayerController(renderer: r, policy: policy, isInterlaced: { _ in false })
        let d = try Fixtures.data("streams/orf1.ts")
        c.play { PCRPacedSource(data: d, gapAt: 2.5, gap: 3) }   // live-paced, 3 s gap 2.5 s in
        var sawBuffering = false, clockAtStall: Double?, clockAfter: Double?
        let flushesAtStart: Int
        _ = await waitFor(c) { $0 == .playing }
        flushesAtStart = r.flushCount
        let end = Date().addingTimeInterval(12)
        while Date() < end {
            if case .buffering = c.phase, !sawBuffering { sawBuffering = true; clockAtStall = CMTimeGetSeconds(r.currentTime) }
            if sawBuffering, c.phase == .playing { clockAfter = CMTimeGetSeconds(r.currentTime); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sawBuffering)
        XCTAssertEqual(r.flushCount, flushesAtStart, "no flush on a stall")
        if let a = clockAtStall, let b = clockAfter { XCTAssertLessThan(abs(b - a), 0.15, "clock resumed where it paused") }
        c.stop()
    }

    /// Channel switch on a shared renderer (the app and the TV harness keep
    /// one): the new channel's clock must not be read from the old one. 6ter's
    /// PTS (~86158 s) is far ahead of orf1's (~308 s); reading the stale clock
    /// made orf1 "starve" 0.1 s after it started.
    func testSwitchToLowerPTSChannelDoesNotStall() async throws {
        let r = Renderer(audioOutput: false)
        let c = PlayerController(renderer: r, policy: fast, isInterlaced: { _ in true })
        let a = try Fixtures.data("streams/6ter.raw.ts"), b = try Fixtures.data("streams/orf1.raw.ts")
        c.play { ScriptedSource(steps: [.data(a), .hang]) }
        let first = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(first)
        try await Task.sleep(for: .milliseconds(500))
        c.play { ScriptedSource(steps: [.data(b), .hang]) }
        let second = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(second)
        var sawBuffering = false
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            if case .buffering = c.phase { sawBuffering = true }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(sawBuffering, "stalled right after the switch")
        XCTAssertEqual(c.stats.rebuffers, 0)
        c.stop()
    }

    /// Real capture (stimmungsgarten, 2026-10-18): programme (SAR 16:11, 25 fps)
    /// cuts to the broadcaster's still slate (SAR 1:1, one I-picture per 2.3 s)
    /// on a new timeline 25530 s later. Playback must carry on into the slate.
    func testTimelineJumpRule() {
        XCTAssertFalse(Pipeline.isNewTimeline(ptsStep: 0.04, elapsed: 0.04))
        XCTAssertFalse(Pipeline.isNewTimeline(ptsStep: 2.29, elapsed: 2.29), "still slate cadence")
        XCTAssertFalse(Pipeline.isNewTimeline(ptsStep: 0.04, elapsed: 4), "delivery gap")
        XCTAssertFalse(Pipeline.isNewTimeline(ptsStep: 3, elapsed: 0.01), "catch-up burst after a gap")
        XCTAssertTrue(Pipeline.isNewTimeline(ptsStep: 25530, elapsed: 0.1), "source switch")
        XCTAssertTrue(Pipeline.isNewTimeline(ptsStep: -5, elapsed: 0.1), "backward")
    }

    /// The same channel 50 minutes later: slate back to the interlaced programme
    /// (SAR 1:1 -> 16:11, progressive -> MBAFF).
    func testSwitchFromStillSlateBackToProgrammePlays() async throws {
        let d = try Fixtures.data("streams/geometry/stimmungsgarten-20261018-132001.raw.ts")
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 30,
                                  reconnectDelays: [0.05, 0.1], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: PlayerController.codedInterlaced)
        c.play { PCRPacedSource(data: d) }
        let restarted = await waitFor(c, timeout: 22) { _ in c.stats.restarts >= 1 }
        XCTAssertTrue(restarted, "the switch starts a new timeline")
        let atSwitch = c.stats.framesEnqueued
        let playing = await waitFor(c, timeout: 6) { $0 == .playing && c.stats.framesEnqueued > atSwitch + 25 }
        XCTAssertTrue(playing, "programme plays after the slate (\(c.phase), enqueued \(c.stats.framesEnqueued - atSwitch))")
        c.stop()
    }

    func testSourceSwitchToStillSlateKeepsPlaying() async throws {
        let d = try Fixtures.data("streams/geometry/stimmungsgarten-20261018-122943.raw.ts")
        let policy = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 30,
                                  reconnectDelays: [0.05, 0.1], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: policy, isInterlaced: PlayerController.codedInterlaced)
        c.play { PCRPacedSource(data: d) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        // The switch reaches the player ~15 s in (the old programme's audio runs
        // on past its video); the slate then needs ~3 deliveries (2.3 s apart)
        // before live-buffer starts it.
        let restarted = await waitFor(c, timeout: 20) { _ in c.stats.restarts == 1 }
        XCTAssertTrue(restarted, "the switch starts a new timeline")
        let atSwitch = c.stats.framesEnqueued
        let replayed = await waitFor(c, timeout: 9) { $0 == .playing && c.stats.framesEnqueued > atSwitch }
        XCTAssertTrue(replayed, "slate pictures reach the renderer (\(c.phase))")
        XCTAssertEqual(c.stats.restarts, 1, "one restart, not one per slate picture")
        c.stop()
    }

    /// The app asks tvOS for a matching display refresh rate (AVDisplayCriteria):
    /// 720p50 and deinterlaced 25i both come out at 50 frames a second.
    func testReportsOutputFrameRate() async throws {
        for (id, il) in [("orf1", false), ("tf-1", true)] {
            let c = controller(interlaced: il)
            c.play { ScriptedSource(steps: [.data(try! Fixtures.data("streams/\(id).ts")), .hang]) }
            let ok = await waitFor(c) { $0 == .playing }
            XCTAssertTrue(ok, id)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(c.stats.outputFrameRate ?? 0, 50, accuracy: 0.5, id)
            c.stop()
        }
    }

    /// bfm-tv on the Apple TV had no sound: video is muxed ahead of its time,
    /// audio close to real time, so a start judged on video lead alone left
    /// every audio buffer arriving after its play time (1690 late). The buffer
    /// depth must cover audio too.
    func testAudioIsNotLateWhenAudioLagsVideoInTheMux() async throws {
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in true })
        let url = Fixtures.root.appendingPathComponent("streams/bfm-tv.raw.ts")
        let size = try Data(contentsOf: url).count
        c.play { FileByteSource(url: url, bytesPerSecond: size / 30) }   // ~30 s capture, real time
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(c.stats.audioLateBuffers, 0, "audio handed over after its play time; min lead \(c.stats.minAudioLeadSeconds ?? -9)")
        c.stop()
    }

    /// Steady real-time delivery (no gaps) must never stall. On the Apple TV
    /// the live-buffer build stalled once per channel with clean delivery.
    func testSteadyDeliveryNeverStalls() async throws {
        for id in ["tf-1", "france-2", "bfm-tv", "novo-19"] {
            let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in true })
            let d = try Fixtures.data("streams/\(id).raw.ts")
            c.play { PCRPacedSource(data: d) }
            let ok = await waitFor(c) { $0 == .playing }
            XCTAssertTrue(ok, id)
            try await Task.sleep(for: .seconds(8))
            XCTAssertEqual(c.stats.rebuffers, 0, "\(id): stalled with steady delivery (min audio lead \(c.stats.minAudioLeadSeconds ?? -9)) \(c.stats.lastPauseInfo ?? "")")
            c.stop()
        }
    }

    /// Audio-track choice: the channel's tracks are listed, and choosing one
    /// switches mid-stream (audio renderer only: no restart, no stall).
    func testChooseAudioTrackSwitchesMidStream() async throws {
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in true })
        c.play { PCRPacedSource(data: try! Fixtures.data("streams/france-2.raw.ts")) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(c.audioTracks.count, 3, "\(c.audioTracks.map(\.label))")
        XCTAssertTrue(c.audioTracks.contains { $0.role == .audioDescription }, "the qad track is labelled")
        let auto = try XCTUnwrap(c.playingAudioTrack)
        let other = try XCTUnwrap(c.audioTracks.first { $0.id != auto })
        c.selectAudio(other.id)
        let end = Date().addingTimeInterval(3)
        while Date() < end, c.playingAudioTrack != other.id { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(c.playingAudioTrack, other.id, "switched to the chosen track")
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(c.phase, .playing)
        XCTAssertEqual(c.stats.restarts, 0, "no restart for an audio switch")
        XCTAssertEqual(c.stats.rebuffers, 0, "no stall for an audio switch")
        c.selectAudio(nil)
        let back = Date().addingTimeInterval(3)
        while Date() < back, c.playingAudioTrack != auto { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(c.playingAudioTrack, auto, "automatic choice restored")
        c.stop()
    }

    /// Requirement 1 of the MetalFX integration: upscaling happens at the last
    /// moment (in the renderer, as each frame goes into the display layer),
    /// never in the decoded cushion. Feeding an HD fixture to a 4K target must
    /// never hold a 4K-sized frame in the backlog, and upscaling itself never
    /// has more than one buffer in flight at the renderer at a time.
    func testUpscalingIsLastMomentAndCushionStaysDecodeSize() async throws {
        guard Upscaler() != nil else { throw XCTSkip("no MetalFX spatial scaler on this machine") }
        let r = Renderer(audioOutput: false)
        var policy = fast
        policy.upscaleTarget = CGSize(width: 3840, height: 2160)
        let c = PlayerController(renderer: r, policy: policy, isInterlaced: { _ in false })
        let d = try Fixtures.data("streams/orf1.ts")     // 1280x720 progressive
        c.play { ScriptedSource(steps: [.data(d), .hang]) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok, "phase \(c.phase)")
        // Let a good number of frames play through so the upscaler is exercised.
        let end = Date().addingTimeInterval(5)
        while Date() < end, r.upscaledFrames == 0 { try await Task.sleep(for: .milliseconds(20)) }
        r.sync()
        XCTAssertGreaterThan(r.upscaledFrames, 0, "some frames were upscaled to the target")
        // A 720p frame has ~1.4 MB of data; a 4K frame ~12.4 MB. The cushion must
        // never hold the 4K size (which the decode-time approach did).
        XCTAssertLessThan(r.peakBacklogFrameBytes, 4 * 1024 * 1024,
                          "the decoded cushion never held an upscaled (4K) frame")
        // The renderer upscales one frame at a time at hand-off, never in parallel.
        XCTAssertLessThanOrEqual(r.peakUpscaledInFlight, 1)
        c.stop()
    }
}

/// Live-like delivery: releases the capture in 188-byte-aligned chunks when
/// their PCR time comes due (what zenith's paced HTTP-TS sender does), not
/// at a constant byte rate.
struct PCRPacedSource: ByteSource {
    let data: Data
    /// Optional delivery gap: nothing is sent for `gap` seconds once media
    /// time `gapAt` (seconds after the first PCR) is reached.
    var gapAt: Double? = nil
    var gap: Double = 0
    func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                let b = [UInt8](data)
                var pcrPID: Int?, firstPCR: Double?, lastPCR: Double?, start = Date()
                var gapAt = self.gapAt
                var off = 0, i = 0
                while i + 188 <= b.count, !Task.isCancelled {
                    let pid = (Int(b[i + 1] & 0x1F) << 8) | Int(b[i + 2])
                    let afc = (b[i + 3] >> 4) & 3
                    if b[i] == 0x47, afc >= 2, b[i + 4] >= 7, b[i + 5] & 0x10 != 0 {
                        if pcrPID == nil { pcrPID = pid }
                        if pid == pcrPID {
                            var base: UInt64 = 0
                            for k in 6...9 { base = (base << 8) | UInt64(b[i + k]) }
                            base = (base << 1) | UInt64(b[i + 10] >> 7)
                            let pcr = Double(base) / 90000
                            if firstPCR == nil { firstPCR = pcr; start = Date() }
                            // PCR discontinuity (source switch): carry on at live pace on the new timeline.
                            if let l = lastPCR, abs(pcr - l) > 1 { firstPCR! += pcr - l - 0.04 }
                            lastPCR = pcr
                            if let g = gapAt, pcr - firstPCR! >= g, gap > 0 {
                                cont.yield(data.subdata(in: off..<i)); off = i
                                try? await Task.sleep(for: .seconds(gap))
                                start = start.addingTimeInterval(gap)   // the server then resumes at its live pace
                                gapAt = nil
                            }
                            let due = start.addingTimeInterval(pcr - firstPCR!)
                            let wait = due.timeIntervalSinceNow
                            if wait > 0.005 {
                                cont.yield(data.subdata(in: off..<i)); off = i
                                try? await Task.sleep(for: .seconds(wait))
                            }
                        }
                    }
                    i += 188
                }
                if off < b.count { cont.yield(data.subdata(in: off..<b.count)) }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }
}
