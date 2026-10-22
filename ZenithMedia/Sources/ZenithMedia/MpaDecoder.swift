import CoreAudioTypes
import Foundation
import ZenithMediaFFI

public struct PCMFrame: Sendable {
    public let samples: [Int16]          // interleaved
    public let channels: Int
    public let sampleRate: Int
    public let labels: [AudioChannelLabel]
}

/// MPEG-1/2 Layer II decoder (oxideav-mp2, incl. multichannel extension). One per track.
public final class MpaDecoder {
    private let handle: OpaquePointer
    private var buffer = [Int16](repeating: 0, count: 1152 * 8)

    public init() { handle = zm_mpa_new() }
    deinit { zm_mpa_free(handle) }

    public func decode(_ frame: Data) -> PCMFrame? {
        var ch: UInt32 = 0, rate: UInt32 = 0
        var labels = [UInt32](repeating: 0, count: 8)
        let cap = buffer.count
        let n = frame.withUnsafeBytes { src -> Int in
            guard let s = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return buffer.withUnsafeMutableBufferPointer { dst in
                labels.withUnsafeMutableBufferPointer { lab in
                    zm_mpa_decode(handle, s, src.count, dst.baseAddress, cap, &ch, &rate, lab.baseAddress)
                }
            }
        }
        guard n > 0, ch > 0 else { return nil }
        return PCMFrame(
            samples: Array(buffer[0..<(n * Int(ch))]), channels: Int(ch), sampleRate: Int(rate),
            labels: labels.prefix(Int(ch)).map { AudioChannelLabel($0) })
    }
}
