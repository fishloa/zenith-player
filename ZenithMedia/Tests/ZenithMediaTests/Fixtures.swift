import Foundation
import XCTest
import ZenithMedia


enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("testdata")

    /// A missing fixture skips the test. The audio, PAFF and deinterlace
    /// fixtures are built by the scripts/make-*-fixtures.sh builders; broadcast
    /// captures (testdata/streams) are not distributed, see
    /// scripts/capture-test-streams.sh.
    static func Missing(path: String) -> XCTSkip {
        XCTSkip("missing fixture \(path) — run the scripts/ fixture builders")
    }

    static func data(_ rel: String) throws -> Data {
        let url = root.appendingPathComponent(rel)
        guard let d = try? Data(contentsOf: url) else { throw Missing(path: url.path) }
        return d
    }

    static func events(_ rel: String) throws -> [DemuxEvent] {
        let d = TsDemuxer()
        d.feed(try data(rel))
        d.finish()
        var out: [DemuxEvent] = []
        while let e = d.nextEvent() { out.append(e) }
        return out
    }

    /// Frame count recorded for a capture in testdata/streams/manifest.tsv.
    static func frames(_ id: String) throws -> Int {
        let m = String(decoding: try data("streams/manifest.tsv"), as: UTF8.self)
        for line in m.split(separator: "\n") {
            let c = line.split(separator: "\t").map(String.init)
            if c.first == id, let f = c.first(where: { $0.hasPrefix("frames=") }), let n = Int(f.dropFirst(7)) { return n }
        }
        throw Missing(path: "manifest entry for \(id)")
    }

    static func tracks(_ ev: [DemuxEvent]) -> [TrackInfo] {
        ev.compactMap { if case .trackAdded(let t) = $0 { return t } else { return nil } }
    }

    static func samples(_ ev: [DemuxEvent], track: UInt32) -> [MediaSample] {
        ev.compactMap { if case .sample(let s) = $0, s.trackID == track { return s } else { return nil } }
    }
}
