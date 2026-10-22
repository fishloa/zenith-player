import Foundation

public protocol ByteSource: Sendable {
    func bytes() -> AsyncThrowingStream<Data, Error>
}

public enum ByteSourceError: Error, Equatable {
    case idle
    case http(Int)
}

/// Live HTTP TS stream, delivered in the pieces URLSession receives
/// (no per-byte iteration: that costs measurable CPU at broadcast bitrates).
public struct HTTPByteSource: ByteSource {
    let url: URL, idleTimeout: TimeInterval
    public init(url: URL, idleTimeout: TimeInterval = 10) {
        self.url = url; self.idleTimeout = idleTimeout
    }

    public func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let delegate = Delegate(cont)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.timeoutInterval = idleTimeout
            let task = session.dataTask(with: req)
            cont.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
            task.resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let cont: AsyncThrowingStream<Data, Error>.Continuation
        init(_ cont: AsyncThrowingStream<Data, Error>.Continuation) { self.cont = cont }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            if let h = response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                cont.finish(throwing: ByteSourceError.http(h.statusCode))
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            cont.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let e = error as? URLError, e.code == .timedOut { cont.finish(throwing: ByteSourceError.idle) }
            else if let error { cont.finish(throwing: error) }
            else { cont.finish() }
            session.finishTasksAndInvalidate()
        }
    }
}

/// File-backed source for tests and the device harness; optionally paced to a bitrate.
public struct FileByteSource: ByteSource {
    let url: URL, bytesPerSecond: Int?, chunk: Int
    public init(url: URL, bytesPerSecond: Int?, chunk: Int = 65536) {
        self.url = url; self.bytesPerSecond = bytesPerSecond; self.chunk = chunk
    }

    public func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let data = try Data(contentsOf: url)
                    var off = 0
                    while off < data.count, !Task.isCancelled {
                        let n = min(chunk, data.count - off)
                        cont.yield(data.subdata(in: off..<off + n))
                        off += n
                        if let bps = bytesPerSecond { try await Task.sleep(for: .seconds(Double(n) / Double(bps))) }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
