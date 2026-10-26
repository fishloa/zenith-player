import Foundation

// State is only touched on `queue`.
final class ByteSourceTransport: Transport, @unchecked Sendable {
    private let queue: DispatchQueue
    private let make: () -> ByteSource
    private let onResponse: (UInt32, Int, [(String, String)]) -> Void
    private let onData: (UInt32, Data) -> Void
    private let onClosed: (UInt32, String?) -> Void

    private var tasks: [UInt32: Task<Void, Never>] = [:]
    private var cancelled: Set<UInt32> = []

    init(queue: DispatchQueue, make: @escaping () -> ByteSource,
         onResponse: @escaping (UInt32, Int, [(String, String)]) -> Void,
         onData: @escaping (UInt32, Data) -> Void,
         onClosed: @escaping (UInt32, String?) -> Void) {
        self.queue = queue
        self.make = make
        self.onResponse = onResponse
        self.onData = onData
        self.onClosed = onClosed
    }

    func start(conn: UInt32, method: String, url: URL, headers: [(String, String)], range: ClosedRange<UInt64>?) {
        tasks[conn]?.cancel()
        cancelled.remove(conn)
        let task = Task { [weak self] in
            guard let self else { return }
            let source = self.make()
            self.queue.async { [weak self] in
                guard let self, !self.cancelled.contains(conn) else { return }
                self.onResponse(conn, 200, [("Content-Type", "video/mp2t")])
            }
            do {
                for try await chunk in source.bytes() {
                    if Task.isCancelled { break }
                    self.queue.async { [weak self] in
                        guard let self, !self.cancelled.contains(conn) else { return }
                        self.onData(conn, chunk)
                    }
                }
                if !Task.isCancelled {
                    self.queue.async { [weak self] in
                        guard let self, !self.cancelled.contains(conn) else { return }
                        self.onClosed(conn, nil)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self.queue.async { [weak self] in
                        guard let self, !self.cancelled.contains(conn) else { return }
                        self.onClosed(conn, error.localizedDescription)
                    }
                }
            }
        }
        tasks[conn] = task
    }

    func cancel(conn: UInt32) {
        cancelled.insert(conn)
        tasks[conn]?.cancel()
        tasks.removeValue(forKey: conn)
    }

    func invalidate() {
        for conn in tasks.keys { cancelled.insert(conn) }
        for t in tasks.values { t.cancel() }
        tasks.removeAll()
    }
}
