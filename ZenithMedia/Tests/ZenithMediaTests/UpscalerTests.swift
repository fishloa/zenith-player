import CoreImage
import CoreMedia
import CoreVideo
import Metal
import XCTest
@testable import ZenithMedia

/// MetalFX upscaling to the screen: SD/HD frames become square-pixel frames
/// at the screen's resolution, shaped by their display aspect.
final class UpscalerTests: XCTestCase {
    /// First decoded pictures of a real capture (720x576, SAR 64:45 = 16:9).
    private func melodieFrames(_ n: Int) throws -> [DecodedFrame] {
        let ev = try Fixtures.events("streams/melodie.ts")
        let track = try XCTUnwrap(Fixtures.tracks(ev).first { $0.codec == .h264 })
        let dec = try VideoDecoder(track: track)
        var frames: [DecodedFrame] = []
        let lock = NSLock()
        dec.onFrames = { f in lock.lock(); frames += f; lock.unlock() }
        for s in Fixtures.samples(ev, track: track.trackID).prefix(40) { dec.decode(s) }
        let tail = dec.flush()
        lock.lock(); frames += tail; let all = frames; lock.unlock()
        return Array(all.prefix(n))
    }

    private func upscaler() throws -> Upscaler {
        guard let u = Upscaler() else { throw XCTSkip("no MetalFX spatial scaler on this machine") }
        return u
    }

    func testUpscalesAnamorphicSDToA16by9FrameAtScreenSize() throws {
        let u = try upscaler()
        let src = try XCTUnwrap(try melodieFrames(1).first)
        let out = try XCTUnwrap(u.upscale(src, pixelAspect: PixelAspect(64, 45), to: CGSize(width: 3840, height: 2160)))
        // 720 x 64/45 = 1024 wide, 576 high: 16:9, so it fills 3840x2160 exactly.
        XCTAssertEqual(CVPixelBufferGetWidth(out.pixelBuffer), 3840)
        XCTAssertEqual(CVPixelBufferGetHeight(out.pixelBuffer), 2160)
        XCTAssertEqual(out.pts, src.pts, "timing unchanged")
        XCTAssertNil(PixelAspectTests.par(out.pixelBuffer), "output pixels are square")
        XCTAssertNotNil(CVPixelBufferGetIOSurface(out.pixelBuffer), "IOSurface-backed, so the display layer takes it without a copy")
    }

    func testAspectIsKeptWhenItDoesNotMatchTheScreen() throws {
        let u = try upscaler()
        let src = try XCTUnwrap(try melodieFrames(1).first)
        // Square pixels: 720x576 is 5:4, so it fits the height: 2700x2160.
        let out = try XCTUnwrap(u.upscale(src, pixelAspect: nil, to: CGSize(width: 3840, height: 2160)))
        XCTAssertEqual(CVPixelBufferGetHeight(out.pixelBuffer), 2160)
        XCTAssertEqual(CVPixelBufferGetWidth(out.pixelBuffer), 2700, accuracy: 2)
    }

    /// Not a gameable "something came out": the picture must match a
    /// high-quality reference scale of the same frame, and carry real detail.
    func testPictureMatchesALanczosReference() throws {
        let u = try upscaler()
        let size = CGSize(width: 3840, height: 2160)
        for src in try melodieFrames(3) {
            let out = try XCTUnwrap(u.upscale(src, pixelAspect: PixelAspect(64, 45), to: size))
            let ref = Self.lanczos(src.pixelBuffer, to: size)
            let got = Self.luma(CIImage(cvPixelBuffer: out.pixelBuffer), size: size)
            let want = Self.luma(ref, size: size)
            XCTAssertGreaterThan(Self.psnr(got, want), 28, "upscaled picture differs from the reference")
            XCTAssertGreaterThan(Self.stddev(got), 10, "flat output (black, grey or constant)")
        }
    }

    func testFramesAlreadyAtScreenSizeAreNotScaled() throws {
        let u = try upscaler()
        let src = try XCTUnwrap(try melodieFrames(1).first)
        XCTAssertNil(u.upscale(src, pixelAspect: PixelAspect(64, 45), to: CGSize(width: 720, height: 405)),
                     "nothing to gain: the caller shows the original frame")
    }

    // MARK: reference + metrics (CoreImage, independent of the implementation)

    static func lanczos(_ pb: CVPixelBuffer, to size: CGSize) -> CIImage {
        let img = CIImage(cvPixelBuffer: pb)
        let f = CIFilter(name: "CILanczosScaleTransform")!
        f.setValue(img, forKey: kCIInputImageKey)
        f.setValue(size.height / img.extent.height, forKey: kCIInputScaleKey)
        f.setValue((size.width / img.extent.width) / (size.height / img.extent.height), forKey: kCIInputAspectRatioKey)
        return f.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// 8-bit luma at a quarter of the size (fast, and insensitive to sub-pixel shifts).
    static func luma(_ img: CIImage, size: CGSize) -> [UInt8] {
        let w = Int(size.width) / 4, h = Int(size.height) / 4
        let scaled = img.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / img.extent.width, y: CGFloat(h) / img.extent.height))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        ctx.render(scaled, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                   format: .RGBA8, colorSpace: nil)
        return (0..<(w * h)).map { i in
            UInt8((299 * Int(rgba[i * 4]) + 587 * Int(rgba[i * 4 + 1]) + 114 * Int(rgba[i * 4 + 2])) / 1000)
        }
    }

    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let mse = zip(a, b).reduce(0.0) { s, p in let d = Double(p.0) - Double(p.1); return s + d * d } / Double(a.count)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    static func stddev(_ a: [UInt8]) -> Double {
        let m = a.reduce(0.0) { $0 + Double($1) } / Double(a.count)
        return (a.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(a.count)).squareRoot()
    }
}
