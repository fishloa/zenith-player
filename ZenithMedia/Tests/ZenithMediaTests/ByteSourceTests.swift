import Network
import XCTest
@testable import ZenithMedia

final class ByteSourceTests: XCTestCase {
    func testFileSourceYieldsWholeFileInChunks() async throws {
        let url = Fixtures.root.appendingPathComponent("audio/mux-aligned.ts")
        let expected = try Data(contentsOf: url)
        var got = Data(), chunks = 0
        for try await c in FileByteSource(url: url, bytesPerSecond: nil, chunk: 65536).bytes() { got += c; chunks += 1 }
        XCTAssertEqual(got, expected)
        XCTAssertEqual(chunks, (expected.count + 65535) / 65536)
    }

    func testHTTPErrorStatusThrows() async throws {
        let server = try NotFoundServer()
        defer { server.stop() }
        let port = try await server.port()
        let src = HTTPByteSource(url: URL(string: "http://127.0.0.1:\(port)/stream/ts/does-not-exist")!, idleTimeout: 5)
        do {
            for try await _ in src.bytes() {}
            XCTFail("expected an error")
        } catch let e as ByteSourceError {
            if case .http(let code) = e { XCTAssertGreaterThanOrEqual(code, 400) } else { XCTFail("\(e)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// A live 1080i channel is ~2 MB/s; delivery must cost little CPU on the TV.
    /// 64 MB through the URLSession path (file:// URL, no network) in well under half a second.
    func testHTTPSourceDeliversBulkDataFast() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zm-bytesource-\(UUID().uuidString).ts")
        let expected = Data((0..<(64 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try expected.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let t0 = Date()
        var got = Data(capacity: expected.count)
        for try await c in HTTPByteSource(url: url).bytes() { got += c }
        let secs = Date().timeIntervalSince(t0)
        XCTAssertEqual(got.count, expected.count)
        XCTAssertTrue(got == expected)
        XCTAssertLessThan(secs, 0.4, "64 MB took \(secs) s")
    }
}

/// Loopback HTTP server that answers every request with 404.
private final class NotFoundServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "zenithmedia.test.http404")

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [queue] c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        listener.start(queue: queue)
    }

    func port() async throws -> UInt16 {
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 { return p }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }
}
