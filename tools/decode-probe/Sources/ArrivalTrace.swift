import Foundation
import ZenithMedia

/// Phase-event log for soak `-trace`: player phase changes. Written as CSV
/// to Library/Caches/traces/<id>.events.csv; run-on-device.sh users copy
/// them off with devicectl.
final class ArrivalTrace: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var events: [(UInt64, String)] = []

    /// Wall clock at a known monotonic instant, to line traces up with other
    /// machines' logs (the Mac's measure-delivery-jitter.py, zenith telemetry).
    private let anchorWall = Date().timeIntervalSince1970
    private let anchorMono = ArrivalTrace.now()

    init(id: String) { self.id = id }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func event(_ e: String) {
        lock.lock(); events.append((Self.now(), e)); lock.unlock()
    }

    func write() {
        lock.lock(); defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("traces")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ev = "time_ns,event\n\(anchorMono),wall_anchor_unix=\(String(format: "%.3f", anchorWall))\n"
        for (t, e) in events { ev += "\(t),\(e)\n" }
        try? ev.write(to: dir.appendingPathComponent("\(id).events.csv"), atomically: true, encoding: .utf8)
    }
}
