import CoreMedia
import XCTest
@testable import ZenithMedia

/// Field-coded (PAFF) channels: transmux pairs both fields into one access
/// unit (rust-broadcast #1161), so VideoToolbox must output one whole frame
/// per sample — the frame count ffmpeg reports for the capture.
final class PAFFDecodeTests: XCTestCase {
    static let paff = ["6ter", "arte", "bfm-tv", "cnews", "cstar", "france-5", "gulli", "l-equipe", "lci", "lcp",
                       "m6", "melodie", "novo-19", "t18", "tf-1", "tfx", "tmc", "w9-hd", "rai-2", "rai-5", "rai-sport"]

    func testEveryPAFFCaptureDecodesWholeFrames() throws {
        for id in Self.paff {
            let ev = try Fixtures.events("streams/\(id).ts")
            let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 }, id)
            let samples = Fixtures.samples(ev, track: track.trackID)
            let dec = try VideoDecoder(track: track)
            var frames: [DecodedFrame] = []
            let lock = NSLock()
            dec.onFrames = { f in lock.lock(); frames += f; lock.unlock() }
            // Count errors after the first second from the join point.
            let joinPTS = samples.first?.pts ?? 0
            let firstGOPEnd = samples.firstIndex { $0.dts - joinPTS > Int64(track.timescale) } ?? samples.count
            var errorsAfterFirstGOP = 0
            for (i, s) in samples.enumerated() {
                let before = dec.errorCount
                dec.decode(s)
                if i >= firstGOPEnd { dec.waitForPending(); errorsAfterFirstGOP += dec.errorCount - before }
            }
            let tail = dec.flush()
            lock.lock(); frames += tail; lock.unlock()
            let refs = Set(String(decoding: try Fixtures.data("streams/\(id).md5"), as: UTF8.self).split(separator: "\n").map(String.init))
            let exact = frames.filter { refs.contains(i420MD5($0.pixelBuffer)) }.count
            print("PAFF \(id): samples=\(samples.count) frames=\(frames.count) expected=\((try? Fixtures.frames(id)) ?? -1) bitexact=\(exact) errors=\(dec.errorCount)")
            // Every decoded frame bit-exact. After an open-GOP recovery-point
            // join VideoToolbox may reject one picture that references the
            // previous GOP (arte); nowhere else.
            XCTAssertEqual(exact, frames.count, "\(id): decoded frames bit-exact")
            XCTAssertLessThanOrEqual(dec.errorCount, 1, id)
            XCTAssertEqual(errorsAfterFirstGOP, 0, "\(id): no decode errors after the first second")
            XCTAssertEqual(frames.count + dec.errorCount, try Fixtures.frames(id), "\(id): one frame per coded frame")
        }
    }
}
