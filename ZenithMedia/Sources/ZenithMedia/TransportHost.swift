import Foundation

final class TransportHost: NSObject, URLSessionDataDelegate, Transport {
    private let queue: DispatchQueue
    private let onResponse: (UInt32, Int, [(String, String)]) -> Void
    private let onData: (UInt32, Data) -> Void
    private let onClosed: (UInt32, String?) -> Void

    private var session: URLSession!
    private var tasks: [UInt32: URLSessionDataTask] = [:]
    private var reverse: [ObjectIdentifier: UInt32] = [:]
    private var reported: Set<UInt32> = []
    private var endedByChallenge: Set<UInt32> = []

    init(queue: DispatchQueue,
         onResponse: @escaping (UInt32, Int, [(String, String)]) -> Void,
         onData: @escaping (UInt32, Data) -> Void,
         onClosed: @escaping (UInt32, String?) -> Void) {
        self.queue = queue
        self.onResponse = onResponse
        self.onData = onData
        self.onClosed = onClosed
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
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

    func cancel(conn: UInt32) {
        tasks[conn]?.cancel()
        if let t = tasks.removeValue(forKey: conn) {
            reverse.removeValue(forKey: ObjectIdentifier(t))
        }
    }

    func invalidate() {
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
        reverse.removeAll()
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
                var headers: [(String, String)] = []
                for (k, v) in http.allHeaderFields {
                    headers.append((String(describing: k), String(describing: v)))
                }
                onResponse(conn, http.statusCode, headers)
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
                var headers: [(String, String)] = []
                for (k, v) in http.allHeaderFields {
                    headers.append((String(describing: k), String(describing: v)))
                }
                onResponse(conn, http.statusCode, headers)
                reported.insert(conn)
            }
            endedByChallenge.insert(conn)
        }
        if let dataTask = task as? URLSessionDataTask { dataTask.cancel() }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
