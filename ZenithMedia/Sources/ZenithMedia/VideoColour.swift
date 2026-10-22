import CoreVideo

/// A signalled colour description: H.264/H.265 VUI wire code points
/// (primaries/transfer/matrix) and the full-range flag.
public struct VideoColour: Equatable, Sendable {
    public let primaries: Int
    public let transfer: Int
    public let matrix: Int
    public let fullRange: Bool

    public init(primaries: Int, transfer: Int, matrix: Int, fullRange: Bool) {
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix; self.fullRange = fullRange
    }

    /// Colour of a stream that does not signal one, from its height: HD
    /// (720 lines and up) is BT.709, SD is BT.601 625 (BT.470 B/G).
    public static func fallback(height: Int) -> VideoColour {
        height >= 720 ? VideoColour(primaries: 1, transfer: 1, matrix: 1, fullRange: false)
                      : VideoColour(primaries: 5, transfer: 5, matrix: 5, fullRange: false)
    }

    var matrixAttachment: CFString {
        switch matrix {
        case 1: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case 5, 6: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case 9, 10: kCVImageBufferYCbCrMatrix_ITU_R_2020
        default: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        }
    }

    var primariesAttachment: CFString {
        switch primaries {
        case 1: kCVImageBufferColorPrimaries_ITU_R_709_2
        case 5, 22: kCVImageBufferColorPrimaries_EBU_3213
        case 4, 6, 7: kCVImageBufferColorPrimaries_SMPTE_C
        case 9: kCVImageBufferColorPrimaries_ITU_R_2020
        case 11, 12: kCVImageBufferColorPrimaries_P3_D65
        default: kCVImageBufferColorPrimaries_ITU_R_709_2
        }
    }

    var transferAttachment: CFString {
        switch transfer {
        case 1, 6, 14, 15: kCVImageBufferTransferFunction_ITU_R_709_2
        case 4: kCVImageBufferTransferFunction_UseGamma
        case 8: kCVImageBufferTransferFunction_Linear
        case 13: kCVImageBufferTransferFunction_sRGB
        case 16: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: kCVImageBufferTransferFunction_ITU_R_709_2
        }
    }

    /// The CoreVideo attachments for a decoded frame of this colour.
    public var attachments: [CFString: CFString] {
        [kCVImageBufferYCbCrMatrixKey: matrixAttachment,
         kCVImageBufferColorPrimariesKey: primariesAttachment,
         kCVImageBufferTransferFunctionKey: transferAttachment]
    }

    /// Tag a decoded picture so the display converts it correctly.
    public func attach(to pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, matrixAttachment, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, primariesAttachment, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, transferAttachment, .shouldPropagate)
    }
}
