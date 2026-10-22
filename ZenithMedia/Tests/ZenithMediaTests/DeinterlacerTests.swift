import CoreMedia
import XCTest
@testable import ZenithMedia

final class DeinterlacerTests: XCTestCase {
    /// Combing metric on luma: mean |Y(2k)−Y(2k+1)| / mean |Y(2k)−Y(2k+2)|.
    /// ~1 or below for clean frames, well above 1 when fields are woven from different instants.
    func comb(_ px: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0)
        var adj = 0, same = 0
        for r in stride(from: 0, to: h - 2, by: 2) {
            for x in 0..<w {
                let a = Int(y[r * s + x]), b = Int(y[(r + 1) * s + x]), c = Int(y[(r + 2) * s + x])
                adj += abs(a - b); same += abs(a - c)
            }
        }
        return Double(adj) / Double(max(same, 1))
    }

    /// Synthetic interlaced frame: a 16 px bright bar at x = 8·field, so the two
    /// fields of each frame show the bar 8 px apart (worst-case combing).
    func syntheticFrame(_ k: Int, w: Int = 128, h: Int = 64) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let px = pb!
        CVPixelBufferLockBaseAddress(px, []); defer { CVPixelBufferUnlockBaseAddress(px, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        for r in 0..<h {
            let field = 2 * k + (r & 1)
            for x in 0..<w { y[r * s + x] = (x >= 8 * field % w && x < 8 * field % w + 16) ? 235 : 16 }
        }
        let c = CVPixelBufferGetBaseAddressOfPlane(px, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(px, 1) * h / 2)
        return px
    }

    func testOutputsTwoFramesPerInputAndRemovesCombing() throws {
        let d = try Deinterlacer()
        let field = CMTime(value: 1800, timescale: 90000)
        var out: [DecodedFrame] = []
        var inputComb = 0.0
        for k in 0..<10 {
            let px = syntheticFrame(k)
            inputComb = max(inputComb, comb(px))
            out += d.push(DecodedFrame(pixelBuffer: px, pts: CMTime(value: Int64(3600 * k), timescale: 90000)),
                          topFieldFirst: true, fieldDuration: field)
        }
        out += d.flush(fieldDuration: field)
        XCTAssertEqual(out.count, 20)
        XCTAssertTrue(zip(out, out.dropFirst()).allSatisfy { $1.pts - $0.pts == field }, "50p cadence")
        XCTAssertGreaterThan(inputComb, 2.0, "input is combed")
        for f in out.dropFirst(2).dropLast(2) { XCTAssertLessThan(comb(f.pixelBuffer), 1.2, "output pts \(f.pts.value)") }
    }

    func testCloseToBwdifOnBroadcastFixtures() throws {
        for id in ["rai-2", "france-2"] {
            let ref = try Fixtures.data("deint/\(id).bwdif.yuv")
            let ev = try Fixtures.events("streams/\(id).ts")
            let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 })
            let dec = try VideoDecoder(track: track)
            var frames: [DecodedFrame] = []
            dec.onFrames = { frames += $0 }
            for s in Fixtures.samples(ev, track: track.trackID).prefix(60) { dec.decode(s) }
            frames += dec.flush()
            let d = try Deinterlacer()
            let field = CMTime(value: 1800, timescale: 90000)
            var out: [DecodedFrame] = []
            for f in frames.prefix(40) { out += d.push(f, topFieldFirst: true, fieldDuration: field) }
            out += d.flush(fieldDuration: field)
            let frameBytes = 1920 * 1080 * 3 / 2
            // Skip the first and last two outputs (edge fields lack temporal neighbours).
            var psnrs: [Double] = []
            for i in 2..<min(out.count, ref.count / frameBytes) - 2 {
                psnrs.append(psnrY(out[i].pixelBuffer, ref.subdata(in: i * frameBytes..<(i * frameBytes + 1920 * 1080))))
            }
            let mean = psnrs.reduce(0, +) / Double(psnrs.count)
            print("DEINT \(id): mean luma PSNR vs bwdif \(String(format: "%.2f", mean)) dB over \(psnrs.count) fields, GPU \(d.lastGPUTime * 1000) ms")
            XCTAssertGreaterThanOrEqual(mean, 45.0, "\(id) — if this fails, report the number to the owner; do not lower the threshold")
            XCTAssertLessThanOrEqual(d.lastGPUTime, 0.004 * 2, "two fields per dispatch pair within budget on the Mac")
        }
    }

    func psnrY(_ px: CVPixelBuffer, _ ref: Data) -> Double {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        var err = 0.0
        ref.withUnsafeBytes { r in
            let rp = r.bindMemory(to: UInt8.self)
            for row in 0..<1080 { for x in 0..<1920 { let d = Double(y[row * s + x]) - Double(rp[row * 1920 + x]); err += d * d } }
        }
        let mse = err / Double(1920 * 1080)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// NV12 pixel buffer from one yuv420p frame.
    func nv12(_ yuv: Data, w: Int, h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let px = pb!
        CVPixelBufferLockBaseAddress(px, []); defer { CVPixelBufferUnlockBaseAddress(px, []) }
        yuv.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self)
            let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
            let ys = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
            for r in 0..<h { for x in 0..<w { y[r * ys + x] = src[r * w + x] } }
            let c = CVPixelBufferGetBaseAddressOfPlane(px, 1)!.assumingMemoryBound(to: UInt8.self)
            let cs = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
            let u = w * h, v = u + (w / 2) * (h / 2)
            for r in 0..<(h / 2) { for x in 0..<(w / 2) {
                c[r * cs + 2 * x] = src[u + r * (w / 2) + x]; c[r * cs + 2 * x + 1] = src[v + r * (w / 2) + x]
            } }
        }
        return px
    }

    func psnrLuma(_ a: Data, _ b: Data, w: Int, h: Int) -> Double {
        var err = 0.0
        a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
            let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) { let d = Double(x[i]) - Double(y[i]); err += d * d }
        } }
        let mse = err / Double(w * h)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    func lumaBytes(_ px: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let y = CVPixelBufferGetBaseAddressOfPlane(px, 0)!.assumingMemoryBound(to: UInt8.self)
        let s = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        var d = Data(capacity: w * h)
        for r in 0..<h { d.append(y + r * s, count: w) }
        return d
    }

    /// Ground truth: 50p progressive channels interlaced into 25i; a perfect
    /// deinterlacer gives back the originals. Bar: no worse than ffmpeg bwdif
    /// on the same input (minus 0.5 dB).
    func testGroundTruthAtLeastBwdif() throws {
        let (w, h) = (1280, 720), fb = 1280 * 720 * 3 / 2, lb = 1280 * 720
        for id in ["orf1", "rai-news-24"] {
            let truth = try Fixtures.data("deint/\(id).truth.yuv")
            let synth = try Fixtures.data("deint/\(id).synth.yuv")
            let bw = try Fixtures.data("deint/\(id).synth.bwdif.yuv")
            let d = try Deinterlacer()
            let field = CMTime(value: 1, timescale: 50)
            var out: [DecodedFrame] = []
            for k in 0..<20 {
                let px = nv12(synth.subdata(in: k * fb..<(k + 1) * fb), w: w, h: h)
                out += d.push(DecodedFrame(pixelBuffer: px, pts: CMTime(value: Int64(k), timescale: 25)), topFieldFirst: true, fieldDuration: field)
            }
            out += d.flush(fieldDuration: field)
            XCTAssertEqual(out.count, 40)
            var ours: [Double] = [], ref: [Double] = []
            for i in 2..<38 {
                let t = truth.subdata(in: i * fb..<(i * fb + lb))
                ours.append(psnrLuma(lumaBytes(out[i].pixelBuffer), t, w: w, h: h))
                ref.append(psnrLuma(bw.subdata(in: i * fb..<(i * fb + lb)), t, w: w, h: h))
            }
            let mo = ours.reduce(0, +) / Double(ours.count), mr = ref.reduce(0, +) / Double(ref.count)
            print("GT \(id): ours \(String(format: "%.2f", mo)) dB, bwdif \(String(format: "%.2f", mr)) dB, worst field ours \(String(format: "%.2f", ours.min()!)) bwdif \(String(format: "%.2f", ref.min()!)), GPU \(String(format: "%.3f", d.lastGPUTime * 1000)) ms")
            XCTAssertGreaterThanOrEqual(mo, mr - 0.5, "\(id): ground-truth quality vs bwdif")
        }
    }
}
