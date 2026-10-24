import XCTest
@testable import ZenithMedia

final class ClientSourceTests: XCTestCase {
    private final class Collected: @unchecked Sendable {
        let lock = NSLock()
        var events: [ClientEvent] = []
        func add(_ e: [ClientEvent]) { lock.lock(); events += e; lock.unlock() }
        var all: [ClientEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func wait(_ c: Collected, _ until: ([ClientEvent]) -> Bool) async throws {
        for _ in 0..<300 { if until(c.all) { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("timed out")
    }

    private static func sampleCount(_ events: [ClientEvent]) -> Int {
        events.filter { if case .media(.sample) = $0 { return true }; return false }.count
    }

    func testPlaysAStreamLikeTheDemuxer() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let expected = try Fixtures.events("streams/tf-1.ts").filter { if case .sample = $0 { return true }; return false }.count
        let chunks = stride(from: 0, to: bytes.count, by: 188 * 700).map { bytes.subdata(in: $0..<min($0 + 188 * 700, bytes.count)) }
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], chunks: chunks) }
        defer { s.stop() }
        let c = Collected()
        let url1 = try await s.baseURL().appendingPathComponent("stream/ts/tf-1")
        let src = try XCTUnwrap(ClientSource(url: url1, onEvents: c.add))
        src.start()
        try await wait(c) { Self.sampleCount($0) >= expected - 2 }
        src.close()
        XCTAssertGreaterThanOrEqual(Self.sampleCount(c.all), expected - 2)
    }

    func testAuthRequiredThenBearerRetries() async throws {
        let s = try LoopbackHTTPServer { r in
            r.headers["authorization"] == "Bearer tok" ? TestResponse(status: 200, chunks: [Data(repeating: 0x47, count: 188)])
                                                        : TestResponse(status: 401, headers: ["WWW-Authenticate": #"Bearer realm="z""#])
        }
        defer { s.stop() }
        let c = Collected()
        let url2 = try await s.baseURL().appendingPathComponent("live.ts")
        let src = try XCTUnwrap(ClientSource(url: url2, onEvents: c.add))
        src.start()
        try await wait(c) { $0.contains { if case .authRequired = $0 { return true }; return false } }
        src.setBearer("tok")
        for _ in 0..<150 { if s.requests.contains(where: { $0.headers["authorization"] == "Bearer tok" }) { break }; try await Task.sleep(for: .milliseconds(20)) }
        src.close()
        XCTAssertTrue(s.requests.contains { $0.headers["authorization"] == "Bearer tok" })
    }

    func testCloseCancelsEverything() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let chunkSize = max(1, bytes.count / 100)
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { off in
            bytes.subdata(in: off..<min(off + chunkSize, bytes.count))
        }
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, headers: ["Content-Type": "video/mp2t"], chunks: chunks) }
        defer { s.stop() }
        let c = Collected()
        let url2 = try await s.baseURL().appendingPathComponent("live.ts")
        let src = try XCTUnwrap(ClientSource(url: url2, onEvents: c.add))
        src.start()
        for _ in 0..<150 where c.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(c.all.isEmpty)
        src.close()
        let n = c.all.count
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(c.all.count, n)
    }

    private final class Box: @unchecked Sendable { var source: ClientSource? }

    func testCloseFromInsideTheCallback() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 404) }
        defer { s.stop() }
        let c = Collected(), box = Box()
        box.source = ClientSource(url: try await s.baseURL().appendingPathComponent("x.ts")) { events in
            c.add(events)
            box.source?.close()
        }
        box.source?.start()
        try await wait(c) { !$0.isEmpty }
    }

    func testWakeKeepsTheEarliestDeadline() {
        var w = WakeSchedule()
        XCTAssertTrue(w.offer(1000))
        XCTAssertFalse(w.offer(5000))
        XCTAssertTrue(w.offer(500))
        w.fired()
        XCTAssertTrue(w.offer(5000))
    }

    func testByteSourcePlaysThroughTheSession() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let c = Collected()
        let src = try XCTUnwrap(ClientSource(bytes: { PCRPacedSource(data: bytes) }, onEvents: c.add))
        src.setRenderedTracks([])
        src.start()
        try await wait(c) { events in events.contains { if case .buffer(.start(at27MHz: _)) = $0 { return true }; return false } }
        src.close()
        XCTAssertGreaterThan(Self.sampleCount(c.all), 0)
    }

    func testByteSourceIsReopenedAfterItEnds() async throws {
        let bytes = try Fixtures.data("streams/tf-1.ts")
        let opens = Counter()
        let c = Collected()
        let src = try XCTUnwrap(ClientSource(bytes: { opens.increment(); return FileByteSource(data: bytes.prefix(188 * 2000)) }, onEvents: c.add))
        src.start()
        for _ in 0..<300 where opens.value < 2 { try await Task.sleep(for: .milliseconds(20)) }
        src.close()
        XCTAssertGreaterThanOrEqual(opens.value, 2)
    }
}


private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

extension FileByteSource {
    init(data: Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? data.write(to: url)
        self.init(url: url, bytesPerSecond: nil)
    }
}
