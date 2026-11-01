import Foundation
import Network

final class TransportHost: NSObject, URLSessionDataDelegate, Transport {
    private let queue: DispatchQueue
    private let onResponse: (UInt32, Int, [(String, String)]) -> Void
    private let onData: (UInt32, Data) -> Void
    private let onClosed: (UInt32, String?) -> Void
    private let onConnected: (UInt32) -> Void

    private var session: URLSession!
    private var tasks: [UInt32: URLSessionDataTask] = [:]
    private var reverse: [ObjectIdentifier: UInt32] = [:]
    private var reported: Set<UInt32> = []
    private var endedByChallenge: Set<UInt32> = []

    private var connections: [UInt32: NWConnection] = [:]
    private var tcpClosed: Set<UInt32> = []
    var tcpConnectionCount: Int { connections.count }

    init(queue: DispatchQueue,
         onResponse: @escaping (UInt32, Int, [(String, String)]) -> Void,
         onData: @escaping (UInt32, Data) -> Void,
         onClosed: @escaping (UInt32, String?) -> Void,
         onConnected: @escaping (UInt32) -> Void) {
        self.queue = queue
        self.onResponse = onResponse
        self.onData = onData
        self.onClosed = onClosed
        self.onConnected = onConnected
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCredentialStorage = nil
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        super.init()
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    func start(conn: UInt32, method: String, url: URL, headers: [(String, String)], range: ClosedRange<UInt64>?) {
        reported.remove(conn)
        endedByChallenge.remove(conn)
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let hasAcceptEncoding = headers.contains { $0.0.lowercased() == "accept-encoding" }
        if !hasAcceptEncoding {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        tasks[conn] = task
        reverse[ObjectIdentifier(task)] = conn
        task.resume()
    }

    func connect(conn: UInt32, host: String, port: UInt16, tls: Bool) {
        if let existing = connections[conn] {
            existing.cancel()
        }
        tcpClosed.remove(conn)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onClosed(conn, "bad port")
            return
        }
        let params: NWParameters = tls ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connections[conn] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard self.connections[conn] === connection else { return }
            switch state {
            case .ready:
                guard !self.tcpClosed.contains(conn) else { return }
                self.onConnected(conn)
                self.receive(conn: conn, connection: connection)
            case .failed(let error):
                guard !self.tcpClosed.contains(conn) else {
                    connection.cancel()
                    return
                }
                self.tcpClosed.insert(conn)
                connection.cancel()
                self.onClosed(conn, error.localizedDescription)
            case .waiting(let error):
                guard !self.tcpClosed.contains(conn) else {
                    connection.cancel()
                    return
                }
                self.tcpClosed.insert(conn)
                connection.cancel()
                self.onClosed(conn, error.localizedDescription)
            case .cancelled:
                self.connections.removeValue(forKey: conn)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(conn: UInt32, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connections[conn] === connection else { return }
            guard !self.tcpClosed.contains(conn) else { return }
            if let data, !data.isEmpty {
                self.onData(conn, data)
            }
            if isComplete {
                self.tcpClosed.insert(conn)
                connection.cancel()
                self.onClosed(conn, nil)
                return
            }
            if let error {
                self.tcpClosed.insert(conn)
                connection.cancel()
                self.onClosed(conn, error.localizedDescription)
                return
            }
            self.receive(conn: conn, connection: connection)
        }
    }

    func send(conn: UInt32, bytes: Data) {
        guard let connection = connections[conn] else { return }
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    func cancel(conn: UInt32) {
        tasks[conn]?.cancel()
        if let t = tasks.removeValue(forKey: conn) {
            reverse.removeValue(forKey: ObjectIdentifier(t))
        }
        tcpClosed.insert(conn)
        if let c = connections[conn] {
            c.cancel()
        }
    }

    func invalidate() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        reverse.removeAll()
        for conn in connections.keys { tcpClosed.insert(conn) }
        for c in connections.values { c.cancel() }
        session.invalidateAndCancel()
    }

    private func conn(for task: URLSessionDataTask) -> UInt32? {
        reverse[ObjectIdentifier(task)]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let conn = conn(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse {
            if !reported.contains(conn) {
                onResponse(conn, http.statusCode, Self.sessionHeaders(http))
                reported.insert(conn)
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let conn = conn(for: dataTask) else { return }
        onData(conn, data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let dataTask = task as? URLSessionDataTask,
              let conn = conn(for: dataTask) else { return }
        tasks.removeValue(forKey: conn)
        reverse.removeValue(forKey: ObjectIdentifier(dataTask))
        reported.remove(conn)
        let clean = endedByChallenge.remove(conn) != nil
        onClosed(conn, clean ? nil : error?.localizedDescription)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let dataTask = task as? URLSessionDataTask,
           let conn = conn(for: dataTask),
           let http = challenge.failureResponse as? HTTPURLResponse {
            if !reported.contains(conn) {
                onResponse(conn, http.statusCode, Self.sessionHeaders(http))
                reported.insert(conn)
            }
            endedByChallenge.insert(conn)
        }
        if let dataTask = task as? URLSessionDataTask { dataTask.cancel() }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private static func sessionHeaders(_ http: HTTPURLResponse) -> [(String, String)] {
        http.allHeaderFields.compactMap { k, v in
            let name = String(describing: k)
            return name.lowercased() == "set-cookie" ? nil : (name, String(describing: v))
        }
    }
}
