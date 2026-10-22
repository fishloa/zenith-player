import Foundation
import ZenithMedia

/// Per-chunk arrival log for live-buffer work (soak `-trace`): monotonic
/// arrival time, chunk size and the last PCR seen in the chunk, plus the
/// player phase changes. Written as CSV to Library/Caches/traces/<id>.csv and
/// <id>.events.csv; run-on-device.sh users copy them off with devicectl.
final class ArrivalTrace: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var rows: [(UInt64, Int, UInt64?)] = []
    private var events: [(UInt64, String)] = []
    private var lbRows: [String] = []
    // TS packet alignment across chunks, and the PCR PID (first PCR seen).
    private var carry = Data()
    private var pcrPID: Int?

    /// Wall clock at a known monotonic instant, to line traces up with other
    /// machines' logs (the Mac's measure-delivery-jitter.py, zenith telemetry).
    private let anchorWall = Date().timeIntervalSince1970
    private let anchorMono = ArrivalTrace.now()

    init(id: String) { self.id = id }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func chunk(_ d: Data, at t: UInt64) {
        lock.lock(); defer { lock.unlock() }
        var buf = carry + d
        var lastPCR: UInt64?
        var i = buf.startIndex
        while buf.endIndex - i >= 188 {
            if buf[i] != 0x47 { i += 1; continue }   // resync
            let b1 = Int(buf[i + 1]), b2 = Int(buf[i + 2]), b3 = Int(buf[i + 3])
            let pid = ((b1 & 0x1F) << 8) | b2
            let afc = (b3 >> 4) & 3
            if afc >= 2, buf[i + 4] >= 7, buf[i + 5] & 0x10 != 0 {
                if pcrPID == nil { pcrPID = pid }
                if pid == pcrPID {
                    var base: UInt64 = 0
                    for k in 6...9 { base = (base << 8) | UInt64(buf[i + k]) }
                    base = (base << 1) | UInt64(buf[i + 10] >> 7)
                    let ext = (UInt64(buf[i + 10] & 1) << 8) | UInt64(buf[i + 11])
                    lastPCR = base * 300 + ext
                }
            }
            i += 188
        }
        carry = buf[i...]
        buf = Data()
        rows.append((t, d.count, lastPCR))
    }

    /// One live-buffer input row (PlayerController.liveBufferLog).
    func liveBuffer(_ row: String) { lock.lock(); lbRows.append(row); lock.unlock() }

    func event(_ e: String) {
        lock.lock(); events.append((Self.now(), e)); lock.unlock()
    }

    func write() {
        lock.lock(); defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("traces")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var csv = "arrival_ns,bytes,pcr_27mhz\n"
        for (t, n, p) in rows { csv += "\(t),\(n),\(p.map(String.init) ?? "")\n" }
        try? csv.write(to: dir.appendingPathComponent("\(id).csv"), atomically: true, encoding: .utf8)
        var ev = "time_ns,event\n\(anchorMono),wall_anchor_unix=\(String(format: "%.3f", anchorWall))\n"
        for (t, e) in events { ev += "\(t),\(e)\n" }
        try? ev.write(to: dir.appendingPathComponent("\(id).events.csv"), atomically: true, encoding: .utf8)
        if !lbRows.isEmpty {
            let lbcsv = "kind,now_us,a,b\n" + lbRows.joined(separator: "\n") + "\n"
            try? lbcsv.write(to: dir.appendingPathComponent("\(id).lb.csv"), atomically: true, encoding: .utf8)
        }
    }
}

/// Wraps a source and timestamps every chunk as it reaches the player.
struct TracingByteSource: ByteSource {
    let inner: ByteSource
    let trace: ArrivalTrace

    func bytes() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await c in inner.bytes() {
                        trace.chunk(c, at: ArrivalTrace.now())
                        cont.yield(c)
                    }
                    trace.event("source_end")
                    cont.finish()
                } catch {
                    trace.event("source_error")
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
