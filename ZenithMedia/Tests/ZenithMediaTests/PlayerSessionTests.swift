import CoreMedia
import XCTest
@testable import ZenithMedia

@MainActor
final class PlayerSessionTests: XCTestCase {
    let fast = PlayerPolicy(startBuffer: 0.5, stallMessageAfter: 0.2, stallReconnectAfter: 0.5,
                            reconnectDelays: [0.05, 0.1], reconnectMax: 0.1, decoderFailuresBeforeReconnect: 3)

    func controller() -> PlayerController {
        PlayerController(renderer: Renderer(audioOutput: false), policy: fast, isInterlaced: { _ in false })
    }

    func waitFor(_ c: PlayerController, timeout: Double = 10, _ pred: (PlayerPhase) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if pred(c.phase) { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }

    func waitForFirstFrame(_ c: PlayerController, timeout: Double = 15) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if c.stats.firstFrameAfter != nil { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testServerCloseReconnects() async throws {
        let c = controller()
        let data = try Fixtures.data("streams/tf-1.ts")
        let opens = OpenCounter()
        c.play {
            opens.increment()
            return PCRPacedSource(data: data)
        }
        let ff = await waitForFirstFrame(c)
        XCTAssertTrue(ff)
        let end = Date().addingTimeInterval(15)
        while Date() < end, opens.value < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(opens.value, 2)
        let settle = Date().addingTimeInterval(8)
        while Date() < settle, c.stats.restarts < 1 || c.phase != .playing { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertGreaterThanOrEqual(c.stats.restarts, 1)
        XCTAssertEqual(c.phase, .playing)
        c.stop()
    }

    func testFiniteFileLoops() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let cut = bytes.prefix(188 * 2000)
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], body: cut) }
        defer { s.stop() }
        let c = controller()
        let url = try await s.baseURL().appendingPathComponent("stream.ts")
        c.play(url: url)
        let ff = await waitForFirstFrame(c)
        XCTAssertTrue(ff)
        let end = Date().addingTimeInterval(20)
        while Date() < end, s.requests.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThanOrEqual(s.requests.count, 3)
        XCTAssertGreaterThanOrEqual(c.stats.starts, 2)
        let playing = await waitFor(c, timeout: 5) { $0 == .playing }
        XCTAssertTrue(playing, "phase \(c.phase)")
        c.stop()
    }

    func testLiveHLSPlays() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let n = bytes.count / 188 / 3 * 188
        let segs = (0..<3).map { bytes.subdata(in: (bytes.startIndex + $0 * n)..<(bytes.startIndex + ($0 + 1) * n)) }
        let base = HLSBase()
        let s = try LoopbackHTTPServer { req in
            if req.path.hasSuffix("index.m3u8") {
                let b = base.url!.absoluteString
                let body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:12\n"
                    + (0..<3).map { "#EXTINF:3.500000,\n\(b)/stream/hls/ts/tf-1/seg\(12 + $0).ts\n" }.joined()
                return TestResponse(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(body.utf8))
            }
            for i in 0..<3 where req.path.hasSuffix("seg\(12 + i).ts") {
                return TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], body: segs[i])
            }
            return TestResponse(status: 404)
        }
        defer { s.stop() }
        base.url = try await s.baseURL()
        let c = controller()
        c.play(url: base.url!.appendingPathComponent("stream/hls/ts/tf-1/index.m3u8"))
        let ff = await waitForFirstFrame(c)
        XCTAssertTrue(ff, "phase \(c.phase), requests \(s.requests.map(\.path))")
        c.stop()
    }

    func testStreamAuthFailureIsReported() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 401, headers: ["WWW-Authenticate": #"Basic realm="tv""#]) }
        defer { s.stop() }
        let c = controller()
        let url = try await s.baseURL().appendingPathComponent("stream.ts")
        c.play(url: url)
        let ok = await waitFor(c, timeout: 5) { $0 == .needsCredentials(host: "127.0.0.1") }
        XCTAssertTrue(ok, "phase \(c.phase)")
        c.stop()
    }

    func testAudioSwitchKeepsPlaying() async throws {
        let c = PlayerController(renderer: Renderer(audioOutput: false), policy: PlayerPolicy(), isInterlaced: { _ in true })
        c.play { PCRPacedSource(data: try! Fixtures.data("streams/france-2.raw.ts")) }
        let ok = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(ok)
        try await Task.sleep(for: .milliseconds(500))
        guard let other = c.audioTracks.first(where: { $0.id != c.playingAudioTrack }) else {
            c.stop(); return
        }
        let before = c.stats.rebuffers
        c.selectAudio(other.id)
        let end = Date().addingTimeInterval(10)
        while Date() < end { if c.phase == .playing { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(c.phase, .playing)
        XCTAssertLessThanOrEqual(c.stats.rebuffers - before, 1)
        c.stop()
    }

    func testTransientForbiddenRecovers() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let counter = RequestCounter()
        let s = try LoopbackHTTPServer { _ in
            let n = counter.increment()
            if n == 1 {
                return TestResponse(status: 403)
            }
            return TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], body: bytes)
        }
        defer { s.stop() }
        let c = controller()
        let url = try await s.baseURL().appendingPathComponent("stream.ts")
        c.play(url: url)
        let playing = await waitFor(c, timeout: 15) { $0 == .playing }
        XCTAssertTrue(playing, "phase \(c.phase)")
        c.stop()
    }

    func testHLSVODLoops() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let vodBytes = bytes.prefix(188 * 6000)
        let n = vodBytes.count / 188 / 3 * 188
        let segs = (0..<3).map { vodBytes.subdata(in: (vodBytes.startIndex + $0 * n)..<(vodBytes.startIndex + ($0 + 1) * n)) }
        let base = HLSBase()
        let s = try LoopbackHTTPServer { req in
            if req.path.hasSuffix("index.m3u8") {
                let b = base.url!.absoluteString
                let body = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:12\n"
                    + (0..<3).map { "#EXTINF:3.500000,\n\(b)/stream/hls/ts/tf-1/seg\(12 + $0).ts\n" }.joined()
                    + "#EXT-X-ENDLIST\n"
                return TestResponse(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(body.utf8))
            }
            for i in 0..<3 where req.path.hasSuffix("seg\(12 + i).ts") {
                return TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], body: segs[i])
            }
            return TestResponse(status: 404)
        }
        defer { s.stop() }
        base.url = try await s.baseURL()
        let c = controller()
        c.play(url: base.url!.appendingPathComponent("stream/hls/ts/tf-1/index.m3u8"))
        let ff = await waitForFirstFrame(c)
        XCTAssertTrue(ff, "phase \(c.phase)")
        let end = Date().addingTimeInterval(25)
        while Date() < end, s.requests.filter({ $0.path.hasSuffix("index.m3u8") }).count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(s.requests.filter({ $0.path.hasSuffix("index.m3u8") }).count, 2)
        XCTAssertNotNil(c.stats.firstFrameAfter)
        let playing = await waitFor(c, timeout: 5) { $0 == .playing }
        XCTAssertTrue(playing, "phase \(c.phase)")
        c.stop()
    }

    func testRTSPFails() async throws {
        let c = controller()
        c.play(url: URL(string: "rtsp://127.0.0.1:1/x")!)
        let failed = await waitFor(c, timeout: 2) { $0 == .failed }
        XCTAssertTrue(failed, "phase \(c.phase)")
        c.stop()
    }

    func testCredentialOnFirstRequest() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], body: bytes) }
        defer { s.stop() }
        let c = controller()
        let url = try await s.baseURL().appendingPathComponent("stream.ts")
        c.play(url: url, credential: .bearer("tok"))
        let ff = await waitForFirstFrame(c)
        XCTAssertTrue(ff, "phase \(c.phase)")
        let req = s.requests.first
        XCTAssertNotNil(req)
        let auth = req?.headers.first(where: { $0.key.lowercased() == "authorization" })?.value
        XCTAssertEqual(auth, "Bearer tok")
        c.stop()
    }
}


private final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

final class HLSBase: @unchecked Sendable { var url: URL? }

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
