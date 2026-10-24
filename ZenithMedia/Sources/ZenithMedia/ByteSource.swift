import Foundation

public protocol ByteSource: Sendable {
    func bytes() -> AsyncThrowingStream<Data, Error>
}

public enum ByteSourceError: Error, Equatable {
    case idle
    case http(Int)
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
