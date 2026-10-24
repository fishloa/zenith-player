import Foundation

struct WakeSchedule {
    private var pending: UInt64?
    mutating func offer(_ atMicros: UInt64) -> Bool {
        if let p = pending, atMicros >= p {
            return false
        }
        pending = atMicros
        return true
    }
    mutating func fired() {
        pending = nil
    }
}

public final class ClientSource: @unchecked Sendable {
    private static let queueKey = DispatchSpecificKey<Void>()
    private let queue: DispatchQueue
    private let onEvents: @Sendable ([ClientEvent]) -> Void
    private var session: ZMSession
    private var transport: Transport!
    private var timer: DispatchSourceTimer?
    private var wakeSchedule = WakeSchedule()
    private var closed = false
    private var hasPlaybackPosition = false

    public convenience init?(url: URL, startBuffer: TimeInterval? = nil, stallMemory: (peak: UInt64, age: UInt64)? = nil,
                             onEvents: @escaping @Sendable ([ClientEvent]) -> Void) {
        self.init(url: url, startBuffer: startBuffer, stallMemory: stallMemory, transport: { queue, onResponse, onData, onClosed in
            TransportHost(queue: queue, onResponse: onResponse, onData: onData, onClosed: onClosed)
        }, onEvents: onEvents)
    }

    public convenience init?(bytes make: @escaping () -> ByteSource, startBuffer: TimeInterval? = nil,
                             stallMemory: (peak: UInt64, age: UInt64)? = nil, onEvents: @escaping @Sendable ([ClientEvent]) -> Void) {
        self.init(url: URL(string: "http://local/stream.ts")!, startBuffer: startBuffer, stallMemory: stallMemory, transport: { queue, onResponse, onData, onClosed in
            ByteSourceTransport(queue: queue, make: make, onResponse: onResponse, onData: onData, onClosed: onClosed)
        }, onEvents: onEvents)
    }

    public init?(url: URL, startBuffer: TimeInterval? = nil, stallMemory: (peak: UInt64, age: UInt64)? = nil,
                 transport makeTransport: TransportFactory, onEvents: @escaping @Sendable ([ClientEvent]) -> Void) {
        let now = Self.nowMicros()
        guard let session = ZMSession(url: url, nowMicros: now, startMicros: UInt64(max(0, (startBuffer ?? 0) * 1_000_000)),
                                      peakMicros: stallMemory?.peak ?? 0, ageMicros: stallMemory?.age ?? 0) else { return nil }
        self.onEvents = onEvents
        self.queue = DispatchQueue(label: "zenith.clientsource")
        self.queue.setSpecific(key: Self.queueKey, value: ())
        self.session = session
        self.transport = nil
        self.transport = makeTransport(self.queue,
            { [weak self] conn, status, headers in
                guard let self, !self.closed else { return }
                self.session.response(conn: conn, status: status, headers: headers, nowMicros: Self.nowMicros())
                self.pump()
            },
            { [weak self] conn, data in
                guard let self, !self.closed else { return }
                self.session.data(conn: conn, data, nowMicros: Self.nowMicros())
                self.pump()
            },
            { [weak self] conn, error in
                guard let self, !self.closed else { return }
                self.session.closed(conn: conn, error: error, nowMicros: Self.nowMicros())
                self.pump()
            })
    }

    public func start() {
        queue.async { [weak self] in self?.pump() }
    }

    public func setPassword(user: String, password: String) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.session.setPassword(user: user, password: password)
            self.pump()
        }
    }

    public func setBearer(_ token: String) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.session.setBearer(token)
            self.pump()
        }
    }

    public func setPlaybackPosition(_ pts27: UInt64?) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.hasPlaybackPosition = true
            self.session.onPlaybackPosition(nowMicros: Self.nowMicros(), position: pts27)
            self.pump()
        }
    }

    public func setRenderedTracks(_ ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.session.setRenderedTracks(ids)
            self.pump()
        }
    }

    public func hint(_ code: UInt32) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.session.hint(code)
            self.pump()
        }
    }

    public func selectVariant(_ index: Int) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            _ = self.session.selectVariant(index)
            self.pump()
        }
    }

    public var stallMemory: (peakUs: UInt64, ageUs: UInt64)? {
        let read: () -> (peakUs: UInt64, ageUs: UInt64)? = { [weak self] in
            guard let self, !self.closed else { return nil }
            guard let m = self.session.stallMemory() else { return nil }
            return (peakUs: m.peakMicros, ageUs: m.ageMicros)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return read()
        }
        return queue.sync(execute: read)
    }

    public func reconnect() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.session.reconnect(nowMicros: Self.nowMicros())
            self.pump()
        }
    }

    public func rejoin(track: UInt32) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.session.rejoin(track: track)
            self.pump()
        }
    }

    public func close() {
        let work = { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.timer?.cancel()
            self.timer = nil
            self.transport.invalidate()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    deinit {
        if closed { return }
        closed = true
        let work = {
            self.timer?.cancel()
            self.timer = nil
            self.transport.invalidate()
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func pump() {
        guard !closed else { return }
        if !hasPlaybackPosition {
            session.onPlaybackPosition(nowMicros: Self.nowMicros(), position: nil)
        }
        while true {
            guard let action = session.nextAction(nowMicros: Self.nowMicros()) else { break }
            switch action {
            case .http(let conn, let method, let url, let headers, let range):
                transport.start(conn: conn, method: method, url: url, headers: headers, range: range)
            case .close(let conn):
                transport.cancel(conn: conn)
            case .wake(let at):
                scheduleWake(atMicros: at)
            }
        }
        var events: [ClientEvent] = []
        while let ev = session.nextEvent() {
            events.append(ev)
        }
        if !events.isEmpty {
            onEvents(events)
        }
    }

    private func scheduleWake(atMicros: UInt64) {
        guard wakeSchedule.offer(atMicros) else { return }
        timer?.cancel()
        let now = Self.nowMicros()
        let rawDelay = atMicros > now ? atMicros - now : 0
        let cap: UInt64 = 24 * 3600 * 1_000_000
        let delay = rawDelay > cap ? cap : rawDelay
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .microseconds(Int(delay)), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            self?.wakeSchedule.fired()
            self?.pump()
        }
        t.resume()
        timer = t
    }

    private static func nowMicros() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }
}
