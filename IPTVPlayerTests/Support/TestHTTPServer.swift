import Foundation
import Network

struct TestRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct TestResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()
}

final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.http")
    private let lock = NSLock()
    private var log: [TestRequest] = []
    private let handler: @Sendable (TestRequest) -> TestResponse

    var requests: [TestRequest] { lock.lock(); defer { lock.unlock() }; return log }

    init(_ handler: @escaping @Sendable (TestRequest) -> TestResponse) throws {
        self.handler = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.read(c, Data())
        }
        listener.start(queue: queue)
    }

    func baseURL() async throws -> URL {
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 { return URL(string: "http://127.0.0.1:\(p)")! }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }

    private func read(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf += data }
            if let req = Self.parse(buf) {
                self.lock.lock(); self.log.append(req); self.lock.unlock()
                let r = self.handler(req)
                var head = "HTTP/1.1 \(r.status) Test\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
                for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
                c.send(content: Data((head + "\r\n").utf8) + r.body, completion: .contentProcessed { _ in c.cancel() })
            } else if done || error != nil {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    static func parse(_ d: Data) -> TestRequest? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[end.upperBound...]
        guard body.count >= length else { return nil }
        return TestRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }
}
