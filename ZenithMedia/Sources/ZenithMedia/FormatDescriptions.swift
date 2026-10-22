import AudioToolbox
import CoreMedia

public struct FormatError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let what: String
    public var description: String { "\(what) failed: \(status)" }
}

public enum FormatDescriptions {
    /// H.264 (avcC) / HEVC (hvcC as `hvc1`: VideoToolbox rejects hev1, probe finding).
    public static func video(_ t: TrackInfo) throws -> CMVideoFormatDescription {
        let (type, atom): (CMVideoCodecType, String) = switch t.codec {
        case .h264: (kCMVideoCodecType_H264, "avcC")
        case .hevc: (kCMVideoCodecType_HEVC, "hvcC")
        default: throw FormatError(status: -1, what: "video(\(t.codec))")
        }
        var ext: [CFString: Any] = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: t.config]]
        if let p = t.pixelAspect, !p.isSquare {
            ext[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: p.h,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: p.v]
        }
        var fd: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: type, width: Int32(t.width), height: Int32(t.height),
            extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { throw FormatError(status: st, what: "CMVideoFormatDescriptionCreate") }
        return fd
    }

    /// Compressed audio handed to AVSampleBufferAudioRenderer (tvOS decodes or passes through).
    public static func audio(_ t: TrackInfo) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Float64(t.sampleRate)
        asbd.mChannelsPerFrame = UInt32(t.channels)
        var cookie: Data?
        var layoutTag: AudioChannelLayoutTag?
        switch t.codec {
        case .aac:
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
            cookie = t.config // ES_Descriptor, the esds magic cookie
        case .ac3, .eac3:
            asbd.mFormatID = t.codec == .ac3 ? kAudioFormatAC3 : kAudioFormatEnhancedAC3
            asbd.mFramesPerPacket = 1536
            layoutTag = t.channels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_C : nil  // AC-3 order: L C R Ls Rs LFE
        default:
            throw FormatError(status: -1, what: "audio(\(t.codec))")
        }
        if layoutTag == nil {
            layoutTag = t.channels == 1 ? kAudioChannelLayoutTag_Mono : t.channels == 2 ? kAudioChannelLayoutTag_Stereo : nil
        }
        var layout = AudioChannelLayout()
        if let layoutTag { layout.mChannelLayoutTag = layoutTag }
        var fd: CMAudioFormatDescription?
        let st = withUnsafePointer(to: &layout) { lp in
            (cookie ?? Data()).withUnsafeBytes { cp in
                CMAudioFormatDescriptionCreate(
                    allocator: nil, asbd: &asbd,
                    layoutSize: layoutTag == nil ? 0 : MemoryLayout<AudioChannelLayout>.size,
                    layout: layoutTag == nil ? nil : lp,
                    magicCookieSize: cookie?.count ?? 0, magicCookie: cookie == nil ? nil : cp.baseAddress,
                    extensions: nil, formatDescriptionOut: &fd)
            }
        }
        guard st == noErr, let fd else { throw FormatError(status: st, what: "CMAudioFormatDescriptionCreate(\(t.codec))") }
        return fd
    }

    /// Interleaved s16 LPCM (in-app MP2 decode) with an explicit channel layout.
    public static func lpcm(channels: Int, sampleRate: Int, labels: [AudioChannelLabel]) throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        let size = MemoryLayout<AudioChannelLayout>.size + max(0, channels - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(channels)
        let descs = UnsafeMutableAudioChannelDescriptionPointer(layout)
        for i in 0..<channels {
            descs[i].mChannelLabel = i < labels.count ? labels[i] : kAudioChannelLabel_Unused
        }
        var fd: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: size, layout: layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        guard st == noErr, let fd else { throw FormatError(status: st, what: "CMAudioFormatDescriptionCreate(lpcm)") }
        return fd
    }
}

/// Pointer to the variable-length mChannelDescriptions array of an AudioChannelLayout.
private func UnsafeMutableAudioChannelDescriptionPointer(_ l: UnsafeMutablePointer<AudioChannelLayout>) -> UnsafeMutablePointer<AudioChannelDescription> {
    UnsafeMutableRawPointer(l).advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
        .assumingMemoryBound(to: AudioChannelDescription.self)
}
