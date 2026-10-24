import CoreAudioTypes
import Foundation
import ZenithMediaFFI

public enum Codec: UInt32, Sendable {
    case other = 0, h264, hevc, aac, ac3, eac3, mpegAudio
}

public enum AudioRole: UInt32, Sendable { case unknown = 0, main, audioDescription, hearingImpaired }
public enum VideoScan: UInt32, Sendable { case unknown = 0, progressive, paff, mbaff, fieldSequence }
public enum JoinDecision: UInt32, Sendable { case keep = 0, joinPoint, dropBeforeRAP, dropNotSelfContained, dropLeading }

public struct TrackInfo: Equatable, Sendable {
    public let trackID: UInt32
    public let codec: Codec
    public let timescale: Int32
    public let width: Int
    public let height: Int
    public let channels: Int
    public let sampleRate: Int
    public let pid: UInt16
    /// avcC / hvcC record, dac3 / dec3 payload, or ES_Descriptor (AAC); empty for MPEG audio.
    public let config: Data
    /// Raw PMT ES_info descriptor loop.
    public let descriptors: Data
    /// Audio: first ISO 639-2 language ("" if none), role, nominal bit/s (0 unknown).
    public var language: String = ""
    public var role: AudioRole = .unknown
    public var bitrate: Int = 0
    /// Video: how the stream is coded.
    public var scan: VideoScan = .unknown
    /// Video: sample aspect ratio from the SPS VUI (nil when not signalled).
    public var pixelAspect: PixelAspect?
    /// Video: signalled colour (nil when not signalled; unsignalled is not
    /// BT.709, see `VideoColour.fallback(height:)`).
    public var colour: VideoColour?

    public init(trackID: UInt32, codec: Codec, timescale: Int32, width: Int, height: Int, channels: Int,
                sampleRate: Int, pid: UInt16, config: Data, descriptors: Data,
                language: String = "", role: AudioRole = .unknown, bitrate: Int = 0, scan: VideoScan = .unknown) {
        self.trackID = trackID; self.codec = codec; self.timescale = timescale; self.width = width
        self.height = height; self.channels = channels; self.sampleRate = sampleRate; self.pid = pid
        self.config = config; self.descriptors = descriptors; self.language = language; self.role = role
        self.bitrate = bitrate; self.scan = scan
    }
}

public struct MediaSample: Sendable {
    public let trackID: UInt32
    public let pts: Int64
    public let dts: Int64
    public let duration: UInt32
    public let isSync: Bool
    public let isRAP: Bool
    public let data: Data
    /// Video: live-join decision from transmux (keep / join point / drop).
    public var join: JoinDecision = .keep
    /// Video: coded fields (0 frame, 1 lone field, 2 pair) and field order if known.
    public var fields: Int = 0
    public var bottomFieldFirst: Bool?
    /// Video: pixel aspect and colour in force for this picture (transmux
    /// display state), when the demuxer tracks it.
    public var pixelAspect: PixelAspect?
    public var colour: VideoColour?
}

public enum DemuxEvent: Sendable {
    case trackAdded(TrackInfo)
    case trackUpdated(TrackInfo)
    case trackRemoved(UInt32)
    case sample(MediaSample)
    case discontinuity(trackID: UInt32?)
    /// A video track's display geometry changed (or was first known), right
    /// before the first picture it affects; `pts` is that picture's.
    case displayChanged(trackID: UInt32, pts: Int64, pixelAspect: PixelAspect?, colour: VideoColour?)
}

/// Streaming MPEG-TS demuxer (rust-broadcast transmux). Not thread-safe: use from one queue.
public final class TsDemuxer {
    private let handle: OpaquePointer

    public init() { handle = zm_demux_new() }
    deinit { zm_demux_free(handle) }

    public func feed(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            zm_demux_feed(handle, base, raw.count)
        }
    }

    public func finish() { zm_demux_finish(handle) }

    /// Restart the live join on a video track (decoder reset, discontinuity).
    public func rejoin(track: UInt32) { zm_demux_rejoin(handle, track) }

    /// The newest PCR seen since the last call, 27 MHz ticks.
    public func takePCR() -> UInt64? {
        var v: UInt64 = 0
        return zm_demux_take_pcr(handle, &v) ? v : nil
    }

    public func nextEvent() -> DemuxEvent? {
        while true {
            var ev = zm_event()
            guard zm_demux_poll(handle, &ev) else { return nil }
            if let e = demuxEvent(from: ev) { return e }
        }
    }
}

func demuxEvent(from ev: zm_event) -> DemuxEvent? {
    func bytes(_ p: UnsafePointer<UInt8>?, _ n: Int) -> Data {
        guard let p, n > 0 else { return Data() }
        return Data(bytes: p, count: n)
    }
    func geometry() -> (PixelAspect?, VideoColour?) {
        let par = ev.pixel_aspect_h > 0 && ev.pixel_aspect_v > 0
            ? PixelAspect(Int(ev.pixel_aspect_h), Int(ev.pixel_aspect_v)) : nil
        let colour = ev.colour_primaries > 0 || ev.colour_transfer > 0 || ev.colour_matrix > 0
            ? VideoColour(primaries: Int(ev.colour_primaries), transfer: Int(ev.colour_transfer),
                          matrix: Int(ev.colour_matrix), fullRange: ev.full_range == 1) : nil
        return (par, colour)
    }
    switch ev.kind {
    case UInt32(ZM_EV_TRACK_ADDED), UInt32(ZM_EV_TRACK_UPDATED):
        var t = TrackInfo(
            trackID: ev.track_id, codec: Codec(rawValue: ev.codec) ?? .other,
            timescale: Int32(ev.timescale), width: Int(ev.width), height: Int(ev.height),
            channels: Int(ev.channels), sampleRate: Int(ev.sample_rate), pid: ev.pid,
            config: bytes(ev.config, ev.config_len), descriptors: bytes(ev.descriptors, ev.descriptors_len))
        t.language = withUnsafeBytes(of: ev.language) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        t.role = AudioRole(rawValue: ev.role) ?? .unknown
        t.bitrate = Int(ev.bitrate)
        t.scan = VideoScan(rawValue: ev.scan) ?? .unknown
        (t.pixelAspect, t.colour) = geometry()
        return ev.kind == UInt32(ZM_EV_TRACK_ADDED) ? .trackAdded(t) : .trackUpdated(t)
    case UInt32(ZM_EV_TRACK_REMOVED):
        return .trackRemoved(ev.track_id)
    case UInt32(ZM_EV_SAMPLE):
        var m = MediaSample(
            trackID: ev.track_id, pts: ev.pts, dts: ev.dts, duration: ev.duration,
            isSync: ev.is_sync, isRAP: ev.is_rap, data: bytes(ev.data, ev.data_len))
        m.join = JoinDecision(rawValue: ev.join) ?? .keep
        m.fields = Int(ev.fields)
        m.bottomFieldFirst = ev.bottom_field_first < 0 ? nil : ev.bottom_field_first == 1
        (m.pixelAspect, m.colour) = geometry()
        return .sample(m)
    case UInt32(ZM_EV_DISPLAY_CHANGED):
        let (par, colour) = geometry()
        return .displayChanged(trackID: ev.track_id, pts: ev.pts, pixelAspect: par, colour: colour)
    case UInt32(ZM_EV_DISCONTINUITY):
        return .discontinuity(trackID: ev.track_id == 0 ? nil : ev.track_id)
    default:
        return nil
    }
}
