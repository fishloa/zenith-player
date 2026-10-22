import Foundation

/// `-throughput <url>`: download an unpaced file (to disk, no per-byte
/// iteration) and report the TV's achievable rate on that path, i.e. the
/// headroom available to catch up after a stall on a live stream.
enum Throughput {
    static func run(url: URL, log: (String) -> Void) async {
        let t0 = Date()
        do {
            let (file, resp) = try await URLSession.shared.download(from: url)
            let secs = Date().timeIntervalSince(t0)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            try? FileManager.default.removeItem(at: file)
            log(String(format: "THROUGHPUT http=%d bytes=%d seconds=%.2f mbit_s=%.1f",
                       (resp as? HTTPURLResponse)?.statusCode ?? 0, bytes, secs, Double(bytes) * 8 / secs / 1e6))
        } catch {
            log("THROUGHPUT error \(error)")
        }
        log("THROUGHPUT DONE")
    }
}
