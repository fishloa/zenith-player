import CoreMedia

/// Turns demuxed audio frames into CMSampleBuffers for AVSampleBufferAudioRenderer.
/// AC-3 / E-AC-3 / AAC stay compressed (tvOS decodes or passes through);
/// MPEG audio is decoded in-app (tvOS has no Layer II decoder) to LPCM.
public final class AudioSampleFactory {
    public var isDecodedInApp: Bool { mpa != nil }
    private let timescale: Int32
    private var format: CMAudioFormatDescription?
    private let mpa: MpaDecoder?
    private var lpcmKey = (0, 0)

    public init(track: TrackInfo) throws {
        timescale = track.timescale
        if track.codec == .mpegAudio {
            mpa = MpaDecoder()
        } else {
            mpa = nil
            format = try FormatDescriptions.audio(track)
        }
    }

    public func make(_ s: MediaSample) -> CMSampleBuffer? {
        let pts = CMTime(value: s.pts, timescale: timescale)
        guard let mpa else { return compressed(s.data, pts: pts) }
        guard let pcm = mpa.decode(s.data) else { return nil }
        if lpcmKey != (pcm.channels, pcm.sampleRate) || format == nil {
            format = try? FormatDescriptions.lpcm(channels: pcm.channels, sampleRate: pcm.sampleRate, labels: pcm.labels)
            lpcmKey = (pcm.channels, pcm.sampleRate)
        }
        let bytes = pcm.samples.withUnsafeBytes { Data($0) }
        return lpcm(bytes, frames: pcm.samples.count / pcm.channels, rate: pcm.sampleRate, pts: pts)
    }

    private func block(_ d: Data) -> CMBlockBuffer? {
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: d.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: d.count, flags: 0,
                                                 blockBufferOut: &bb) == noErr, let bb else { return nil }
        _ = d.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: d.count) }
        return bb
    }

    private func compressed(_ d: Data, pts: CMTime) -> CMSampleBuffer? {
        guard let format, let bb = block(d) else { return nil }
        var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(d.count))
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
            presentationTimeStamp: pts, packetDescriptions: &desc, sampleBufferOut: &sb)
        return sb
    }

    private func lpcm(_ d: Data, frames: Int, rate: Int, pts: CMTime) -> CMSampleBuffer? {
        guard let format, let bb = block(d) else { return nil }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}
