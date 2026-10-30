import Foundation
import ZenithMediaFFI

public enum SessionStatus: Equatable, Sendable {
    case establishing, live, stalled(seconds: Int), reconnecting(attempt: Int), notFound, waitingForCredentials, ended
}

public enum PauseReason: Sendable, Equatable {
    case unknown, noData, dataArriving, discontinuity, reprime
    public var name: String {
        switch self {
        case .unknown: return "unknown"
        case .noData: return "no_data"
        case .dataArriving: return "data_arriving"
        case .discontinuity: return "discontinuity"
        case .reprime: return "reprime"
        }
    }
    public init(code: UInt8) {
        switch code {
        case 1: self = .noData
        case 2: self = .dataArriving
        case 3: self = .discontinuity
        case 4: self = .reprime
        default: self = .unknown
        }
    }
}

public enum BufferEvent: Equatable, Sendable {
    case start(at27MHz: UInt64)
    case pause(holdAt27MHz: UInt64, starvingTrack: UInt32?, reason: PauseReason)
    case resume(at27MHz: UInt64)
}

public enum ClientEvent: Sendable {
    case media(DemuxEvent)
    case status(SessionStatus)
    case authRequired(scheme: String, realm: String?, origin: String, resourceMetadata: URL?)
    case authRejected(status: Int)
    case forbidden(status: Int)
    case starved(withData: Bool)
    case finite(expectedBytes: UInt64)
    case buffer(BufferEvent)
    case variants(chosen: Int, lines: [String])
    case error(name: String, fatal: Bool)
}

public enum SessionAction: Sendable {
    case http(conn: UInt32, method: String, url: URL, headers: [(String, String)], range: ClosedRange<UInt64>?)
    case close(conn: UInt32)
    case wake(atMicros: UInt64)
}

extension SessionAction: Equatable {
    public static func == (lhs: SessionAction, rhs: SessionAction) -> Bool {
        switch (lhs, rhs) {
        case (.http(let lc, let lm, let lu, let lh, let lr), .http(let rc, let rm, let ru, let rh, let rr)):
            return lc == rc && lm == rm && lu == ru && lr == rr && headersEqual(lh, rh)
        case (.close(let a), .close(let b)):
            return a == b
        case (.wake(let a), .wake(let b)):
            return a == b
        default:
            return false
        }
    }
}

private func headersEqual(_ a: [(String, String)], _ b: [(String, String)]) -> Bool {
    guard a.count == b.count else { return false }
    for (i, x) in a.enumerated() {
        if x.0 != b[i].0 || x.1 != b[i].1 { return false }
    }
    return true
}

final class ZMSession {
    private let handle: OpaquePointer

    init?(url: URL, nowMicros: UInt64) {
        guard let h = zm_session_open(url.absoluteString, nowMicros) else { return nil }
        handle = h
    }

    init?(url: URL, nowMicros: UInt64, startMicros: UInt64, peakMicros: UInt64, ageMicros: UInt64) {
        guard let h = zm_session_open_ex(url.absoluteString, nowMicros, startMicros, peakMicros, ageMicros) else { return nil }
        handle = h
    }

    init?(url: URL, nowMicros: UInt64, peakMicros: UInt64, ageMicros: UInt64) {
        guard let h = zm_session_open_with_memory(url.absoluteString, nowMicros, peakMicros, ageMicros) else { return nil }
        handle = h
    }

    deinit { zm_session_free(handle) }

    func nextAction(nowMicros: UInt64) -> SessionAction? {
        while true {
            var a = zm_action()
            guard zm_session_poll_action(handle, nowMicros, &a) else { return nil }
            let kind = a.kind
            switch kind {
            case UInt32(ZM_ACT_HTTP):
                let method = a.method != nil ? String(cString: a.method!) : "GET"
                let urlStr = a.url != nil ? String(cString: a.url!) : ""
                guard let url = URL(string: urlStr) else {
                    closed(conn: a.conn, error: "bad url", nowMicros: nowMicros)
                    continue
                }
                var headers: [(String, String)] = []
                if let hp = a.headers {
                    let s = String(cString: hp)
                    for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                        if let idx = line.firstIndex(of: ":") {
                            let name = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                            headers.append((name, value))
                        }
                    }
                }
                let range: ClosedRange<UInt64>? = a.has_range ? a.range_start...(a.range_start + (a.range_len > 0 ? a.range_len - 1 : 0)) : nil
                return .http(conn: a.conn, method: method, url: url, headers: headers, range: range)
            case UInt32(ZM_ACT_CLOSE):
                return .close(conn: a.conn)
            case UInt32(ZM_ACT_WAKE):
                return .wake(atMicros: a.wake_us)
            default:
                continue
            }
        }
    }

    func nextEvent() -> ClientEvent? {
        while true {
            var ev = zm_event()
            guard zm_session_poll(handle, &ev) else { return nil }
            if let e = clientEvent(from: ev) { return e }
        }
    }

    func response(conn: UInt32, status: Int, headers: [(String, String)], nowMicros: UInt64) {
        var s = ""
        for (k, v) in headers { s += "\(k): \(v)\n" }
        s.withCString { ptr in
            zm_session_on_response(handle, conn, UInt16(status), ptr, nowMicros)
        }
    }

    func data(conn: UInt32, _ bytes: Data, nowMicros: UInt64) {
        bytes.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            zm_session_on_data(handle, conn, base, raw.count, nowMicros)
        }
    }

    func closed(conn: UInt32, error: String?, nowMicros: UInt64) {
        if let error {
            error.withCString { ptr in
                zm_session_on_closed(handle, conn, ptr, nowMicros)
            }
        } else {
            zm_session_on_closed(handle, conn, nil, nowMicros)
        }
    }

    @discardableResult
    func setPassword(user: String, password: String) -> Bool {
        return user.withCString { uptr in
            password.withCString { pptr in
                zm_session_set_password(handle, uptr, pptr)
            }
        }
    }

    @discardableResult
    func setBearer(_ token: String) -> Bool {
        return token.withCString { ptr in
            zm_session_set_bearer(handle, ptr)
        }
    }

    func reconnect(nowMicros: UInt64) {
        zm_session_reconnect(handle, nowMicros)
    }

    func rejoin(track: UInt32) {
        zm_session_rejoin(handle, track)
    }

    func onPlaybackPosition(nowMicros: UInt64, position: UInt64?) {
        if let position {
            zm_session_on_playback_position(handle, nowMicros, true, position)
        } else {
            zm_session_on_playback_position(handle, nowMicros, false, 0)
        }
    }

    func setRenderedTracks(_ ids: [UInt32]) {
        if ids.isEmpty {
            zm_session_set_rendered_tracks(handle, nil, 0)
        } else {
            ids.withUnsafeBufferPointer { buf in
                zm_session_set_rendered_tracks(handle, buf.baseAddress, buf.count)
            }
        }
    }

    func hint(_ code: UInt32) {
        zm_session_hint(handle, code)
    }

    func selectVariant(_ index: Int) -> Bool {
        zm_session_select_variant(handle, index)
    }

    func stallMemory() -> (peakMicros: UInt64, ageMicros: UInt64)? {
        var peak: UInt64 = 0
        var age: UInt64 = 0
        guard zm_session_stall_memory(handle, &peak, &age) else { return nil }
        return (peak, age)
    }

    func bufferStats() -> (stalls: Int, reprimes: Int, discontinuities: Int, longestFreeze: Double) {
        var s = zm_buffer_stats()
        zm_session_buffer_stats(handle, &s)
        return (stalls: Int(s.stalls), reprimes: Int(s.reprimes), discontinuities: Int(s.discontinuities), longestFreeze: Double(s.longest_freeze_us) / 1e6)
    }

    func clientEvent(from ev: zm_event) -> ClientEvent? {
        if ev.kind <= 6 {
            if let de = demuxEvent(from: ev) { return .media(de) }
            return nil
        }
        switch ev.kind {
        case UInt32(ZM_EV_STATUS):
            let status: SessionStatus
            switch ev.status {
            case 1: status = .establishing
            case 2: status = .live
            case 3: status = .stalled(seconds: Int(ev.status_value))
            case 4: status = .reconnecting(attempt: Int(ev.status_value))
            case 5: status = .notFound
            case 6: status = .waitingForCredentials
            case 7: status = .ended
            default: status = .establishing
            }
            return .status(status)
        case UInt32(ZM_EV_AUTH_REQUIRED):
            let scheme = ev.auth_scheme != nil ? String(cString: ev.auth_scheme!) : ""
            let realm = ev.auth_realm != nil ? String(cString: ev.auth_realm!) : nil
            let origin = ev.auth_origin != nil ? String(cString: ev.auth_origin!) : ""
            let metadata = ev.auth_metadata != nil ? URL(string: String(cString: ev.auth_metadata!)) : nil
            return .authRequired(scheme: scheme, realm: realm, origin: origin, resourceMetadata: metadata)
        case UInt32(ZM_EV_AUTH_REJECTED):
            return .authRejected(status: Int(ev.http_status))
        case UInt32(ZM_EV_FORBIDDEN):
            return .forbidden(status: Int(ev.http_status))
        case UInt32(ZM_EV_STARVED):
            return .starved(withData: ev.starved_with_data != 0)
        case UInt32(ZM_EV_FINITE):
            return .finite(expectedBytes: ev.status_value)
        case UInt32(ZM_EV_BUFFER):
            switch ev.status {
            case 1: return .buffer(.start(at27MHz: ev.status_value))
            case 2: return .buffer(.pause(holdAt27MHz: ev.status_value, starvingTrack: ev.track_id == 0 ? nil : ev.track_id, reason: PauseReason(code: UInt8(ev.pause_reason))))
            case 3: return .buffer(.resume(at27MHz: ev.status_value))
            default: return nil
            }
        case UInt32(ZM_EV_VARIANTS):
            let chosen = Int(ev.status)
            let text = ev.text != nil ? String(cString: ev.text!) : ""
            let lines = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return .variants(chosen: chosen, lines: lines)
        case UInt32(ZM_EV_ERROR):
            let name = ev.text != nil ? String(cString: ev.text!) : ""
            return .error(name: name, fatal: ev.status != 0)
        default:
            return nil
        }
    }
}
