import CoreMedia
import CryptoKit
import XCTest
@testable import ZenithMedia

final class VideoDecoderTests: XCTestCase {
    func testReorderBufferOrdersByPTS() {
        var b = ReorderBuffer<String>(depth: 2)
        XCTAssertTrue(b.push(pts: 30, "c").isEmpty)
        XCTAssertTrue(b.push(pts: 10, "a").isEmpty)
        XCTAssertEqual(b.push(pts: 20, "b").map(\.1), ["a"])
        XCTAssertEqual(b.drain().map(\.1), ["b", "c"])
    }

    private func decodeAll(_ rel: String) throws -> (VideoDecoder, [DecodedFrame]) {
        let ev = try Fixtures.events(rel)
        let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 || $0.codec == .hevc })
        let dec = try VideoDecoder(track: track)
        var frames: [DecodedFrame] = []
        let lock = NSLock()
        dec.onFrames = { f in lock.lock(); frames += f; lock.unlock() }
        for s in Fixtures.samples(ev, track: track.trackID) { XCTAssertEqual(dec.decode(s), noErr) }
        let tail = dec.flush()
        lock.lock(); frames += tail; lock.unlock()
        return (dec, frames)
    }

    func testMBAFFDecodesBitExactInPTSOrder() throws {
        let (dec, frames) = try decodeAll("streams/rai-2.ts")
        XCTAssertEqual(frames.count, try Fixtures.frames("rai-2"))
        XCTAssertEqual(dec.errorCount, 0)
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.pts < $1.pts }, "PTS order")
        let refs = Set(String(decoding: try Fixtures.data("streams/rai-2.md5"), as: UTF8.self).split(separator: "\n").map(String.init))
        let exact = frames.filter { refs.contains(i420MD5($0.pixelBuffer)) }.count
        XCTAssertEqual(exact, try Fixtures.frames("rai-2"), "macOS VT software decode is bit-exact on rai-2 (probe finding)")
    }

    func testProgressiveAndHEVC() throws {
        XCTAssertEqual(try decodeAll("streams/orf1.ts").1.count, try Fixtures.frames("orf1"))
        XCTAssertEqual(try decodeAll("streams/rai-news-24.ts").1.count, try Fixtures.frames("rai-news-24"))
    }

    /// Frames leave the reorder stage as soon as no later frame can precede
    /// them (PTS <= DTS of the frame just decoded), not after a fixed depth.
    func testLowLatencyRelease() throws {
        for rel in ["streams/orf1.ts", "streams/tf-1.ts"] {
            let ev = try Fixtures.events(rel)
            let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 })
            let dec = try VideoDecoder(track: track)
            var delivered = 0
            let lock = NSLock()
            dec.onFrames = { f in lock.lock(); delivered += f.count; lock.unlock() }
            var worstLag = 0
            for (i, s) in Fixtures.samples(ev, track: track.trackID).prefix(100).enumerated() {
                dec.decode(s)
                dec.waitForPending()
                lock.lock(); worstLag = max(worstLag, i + 1 - delivered); lock.unlock()
            }
            XCTAssertLessThanOrEqual(worstLag, 4, "\(rel): frames held back")
        }
    }

    /// Review M2: a sample VT rejects synchronously must not leave a DTS entry behind.
    func testRejectedSampleLeavesNoPendingDTS() throws {
        let ev = try Fixtures.events("streams/orf1.ts")
        let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 })
        let dec = try VideoDecoder(track: track)
        dec.invalidate()   // every decode now fails synchronously
        for i in 0..<50 { dec.decode(MediaSample(trackID: 1, pts: Int64(i), dts: Int64(i), duration: 0, isSync: true, isRAP: true, data: Data([0, 0, 0, 1, 9]))) }
        XCTAssertEqual(dec.pendingDTSCount, 0)
    }
}

/// MD5 of the frame as planar yuv420p — the bytes ffmpeg's framemd5 hashes.
func i420MD5(_ px: CVPixelBuffer) -> String {
    CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
    let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
    var md5 = Insecure.MD5()
    let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
    for r in 0..<h { md5.update(bufferPointer: UnsafeRawBufferPointer(start: y + r * ys, count: w)) }
    let c = CVPixelBufferGetBaseAddressOfPlane(px, 1)!.assumingMemoryBound(to: UInt8.self)
    let cs = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
    var row = [UInt8](repeating: 0, count: w / 2)
    for plane in 0..<2 {
        for r in 0..<(h / 2) {
            for x in 0..<(w / 2) { row[x] = c[r * cs + 2 * x + plane] }
            row.withUnsafeBytes { md5.update(bufferPointer: $0) }
        }
    }
    return md5.finalize().map { String(format: "%02x", $0) }.joined()
}


/// The decode worker submits frames while the pipeline replaces or stops the
/// decoder on another queue: invalidating mid-decode crashed VideoToolbox
/// (EXC_BAD_ACCESS in RemoteVideoDecoder_DecodeFrameWithOptions).
final class VideoDecoderConcurrencyTests: XCTestCase {
    func testInvalidateWhileDecodingOnAnotherQueueIsSafe() throws {
        let ev = try Fixtures.events("streams/tf-1.ts")
        let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 })
        let samples = Fixtures.samples(ev, track: track.trackID)
        for _ in 0..<40 {
            let dec = try VideoDecoder(track: track)
            let worker = DispatchQueue(label: "test.decode")
            let started = DispatchSemaphore(value: 0)
            worker.async {
                started.signal()
                for s in samples.prefix(60) { dec.decode(s) }
            }
            started.wait()
            usleep(UInt32.random(in: 0...3000))
            dec.invalidate()               // pipeline queue: decoder replaced / stopped
            worker.sync {}
            // Decoding after invalidation is a no-op error, never a crash.
            XCTAssertNotEqual(dec.decode(samples[0]), noErr)
        }
    }
}
