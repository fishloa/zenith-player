import CoreVideo

/// Sample (pixel) aspect ratio from the SPS VUI, e.g. 64:45 or 16:11 for
/// anamorphic 16:9 SD. Square pixels are 1:1.
public struct PixelAspect: Equatable, Sendable {
    public let h: Int
    public let v: Int
    public init(_ h: Int, _ v: Int) { self.h = h; self.v = v }

    public var isSquare: Bool { h == v }

    /// Stamp a decoded picture so the display layer (via the format
    /// description built from it) shows it at the right shape.
    public static func attach(_ p: PixelAspect?, to pb: CVPixelBuffer) {
        guard let p, !p.isSquare else {
            CVBufferRemoveAttachment(pb, kCVImageBufferPixelAspectRatioKey)
            return
        }
        let d: [CFString: Any] = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: p.h,
                                  kCVImageBufferPixelAspectRatioVerticalSpacingKey: p.v]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, d as CFDictionary, .shouldPropagate)
    }

    /// The pixel aspect a decoded frame carries (as stamped by `attach`).
    public static func of(_ pb: CVPixelBuffer) -> PixelAspect? {
        guard let d = CVBufferCopyAttachment(pb, kCVImageBufferPixelAspectRatioKey, nil) as? [CFString: Any],
              let h = d[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int,
              let v = d[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int else { return nil }
        return PixelAspect(h, v)
    }
}
