import XCTest
@testable import ZenithMedia

final class TransportHostTests: XCTestCase {
    private let q = DispatchQueue(label: "test.transport")

    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var responses: [(UInt32, Int, [(String, String)])] = []
        var bytes: [UInt32: Data] = [:]
        var closed: [(UInt32, String?)] = []
    }

    private func host(_ log: Log) -> TransportHost {
        TransportHost(queue: q,
                      onResponse: { c, s, h in log.lock.lock(); log.responses.append((c, s, h)); log.lock.unlock() },
                      onData: { c, d in log.lock.lock(); log.bytes[c, default: Data()] += d; log.lock.unlock() },
                      onClosed: { c, e in log.lock.lock(); log.closed.append((c, e)); log.lock.unlock() })
    }

    private func waitClosed(_ log: Log, _ n: Int) async throws {
        for _ in 0..<200 {
            log.lock.lock(); let done = log.closed.count >= n; log.lock.unlock()
            if done { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out")
    }

    func testStreamsChunksAndCloses() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, chunks: [Data(repeating: 1, count: 1000), Data(repeating: 2, count: 500)]) }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        h.start(conn: 7, method: "GET", url: try await s.baseURL().appendingPathComponent("x.ts"), headers: [("X-A", "1")], range: nil)
        try await waitClosed(log, 1)
        XCTAssertEqual(log.responses.first?.0, 7)
        XCTAssertEqual(log.responses.first?.1, 200)
        XCTAssertEqual(log.bytes[7]?.count, 1500)
        XCTAssertNil(log.closed.first?.1)
        XCTAssertEqual(s.requests.first?.headers["x-a"], "1")
    }

    func testCookiesAreKeptByTheHostNotPassedOn() async throws {
        let s = try LoopbackHTTPServer { r in
            r.path == "/a"
                ? TestResponse(status: 302, headers: ["Location": "/b", "Set-Cookie": "sid=abc; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT"])
                : TestResponse(status: 200)
        }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        let base = try await s.baseURL()
        h.start(conn: 1, method: "GET", url: base.appendingPathComponent("a"), headers: [], range: nil)
        try await waitClosed(log, 1)
        XCTAssertFalse(log.responses.first?.2.contains { $0.0.lowercased() == "set-cookie" } ?? true)
        h.start(conn: 2, method: "GET", url: base.appendingPathComponent("b"), headers: [], range: nil)
        try await waitClosed(log, 2)
        XCTAssertEqual(s.requests.last?.headers["cookie"], "sid=abc")
    }

    func testRedirectIsNotFollowed() async throws {
        let s = try LoopbackHTTPServer { r in
            r.path == "/a" ? TestResponse(status: 302, headers: ["Location": "/b"]) : TestResponse(status: 200)
        }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        h.start(conn: 1, method: "GET", url: try await s.baseURL().appendingPathComponent("a"), headers: [], range: nil)
        try await waitClosed(log, 1)
        XCTAssertEqual(log.responses.first?.1, 302)
        XCTAssertTrue(log.responses.first?.2.contains { $0.0.lowercased() == "location" && $0.1 == "/b" } ?? false)
        XCTAssertEqual(s.requests.count, 1)
    }

    func testUnauthorizedIsPassedThrough() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 401, headers: ["WWW-Authenticate": #"Basic realm="tv""#]) }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        h.start(conn: 2, method: "GET", url: try await s.baseURL().appendingPathComponent("p"), headers: [], range: nil)
        try await waitClosed(log, 1)
        XCTAssertEqual(log.responses.first?.1, 401)
        XCTAssertEqual(s.requests.count, 1)
        XCTAssertNil(log.closed.first?.1, "a 401 ends the transfer cleanly")
    }

    func testStaleCallbacksAreDropped() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, chunks: (0..<20).map { _ in Data(repeating: 0, count: 10_000) }) }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        h.start(conn: 3, method: "GET", url: try await s.baseURL().appendingPathComponent("p"), headers: [], range: nil)
        try await Task.sleep(for: .milliseconds(60))
        q.sync { h.cancel(conn: 3) }
        log.lock.lock(); let before = log.bytes[3]?.count ?? 0; log.lock.unlock()
        try await Task.sleep(for: .milliseconds(400))
        log.lock.lock(); let after = log.bytes[3]?.count ?? 0; let closes = log.closed.count; log.lock.unlock()
        XCTAssertEqual(before, after)
        XCTAssertEqual(closes, 0)
    }

    func testRangeHeader() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 206) }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        h.start(conn: 4, method: "GET", url: try await s.baseURL().appendingPathComponent("p"), headers: [], range: 100...199)
        try await waitClosed(log, 1)
        XCTAssertEqual(s.requests.first?.headers["range"], "bytes=100-199")
    }

    func testCookiesAreNotSharedBetweenHosts() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200, headers: ["Set-Cookie": "a=1; Path=/"]) }
        defer { s.stop() }
        let base = try await s.baseURL()
        let log1 = Log(); let h1 = host(log1)
        h1.start(conn: 1, method: "GET", url: base.appendingPathComponent("one"), headers: [], range: nil)
        try await waitClosed(log1, 1)
        let log2 = Log(); let h2 = host(log2)
        h2.start(conn: 1, method: "GET", url: base.appendingPathComponent("two"), headers: [], range: nil)
        try await waitClosed(log2, 1)
        XCTAssertEqual(s.requests.count, 2)
        XCTAssertNil(s.requests[1].headers["cookie"])
    }

    func testIdentityEncoding() async throws {
        let s = try LoopbackHTTPServer { _ in TestResponse(status: 200) }
        defer { s.stop() }
        let log = Log(); let h = host(log)
        h.start(conn: 1, method: "GET", url: try await s.baseURL().appendingPathComponent("p"), headers: [], range: nil)
        try await waitClosed(log, 1)
        XCTAssertEqual(s.requests.first?.headers["accept-encoding"], "identity")
    }
}
