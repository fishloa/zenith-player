import CoreMedia
import Foundation
import ZenithMediaFFI

/// rust-broadcast's live-buffer controller (via zenith-media's C ABI): it
/// measures delivery jitter, keeps the buffer target and decides when to
/// start, pause and resume. The pipeline feeds it chunks, per-track media
/// ends and clock ticks, and applies its decisions; nothing here is tuned
/// by hand. Not thread-safe: use from the pipeline queue.
final class LiveBuffer {
    enum Decision: Equatable {
        case start(CMTime)
        case pause(holdAt: CMTime, starvingTrack: UInt32?)
        case resume(CMTime)
    }

    struct Stats { var state: UInt32; var leadUs: Int64; var targetUs: UInt64; var stalls: UInt32; var limitingTrack: UInt32? }

    private let p: OpaquePointer
    /// Every input, as CSV rows "kind,now_us,a,b" (chunk: bytes, pcr|""; media:
    /// track, end_27mhz; tick: has_pos, playback_27mhz; hint: code): exact
    /// replay data for live-buffer goldens.
    var inputLog: ((String) -> Void)?

    /// `initialStart`: cold-start target, seconds. `seed`: the session's
    /// stall memory from the previous connection (peak, age in µs).
    init?(initialStart: Double, seed: (peak: UInt64, age: UInt64)? = nil) {
        guard let h = zm_lb_new(UInt64(max(0, initialStart) * 1e6), seed?.peak ?? 0, seed?.age ?? 0) else { return nil }
        p = h
    }
    deinit { zm_lb_free(p) }

    static func nowUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    /// PTS-domain 27 MHz ticks.
    static func ticks(_ t: CMTime) -> UInt64 {
        let v = CMTimeConvertScale(t, timescale: 27_000_000, method: .roundTowardZero).value
        return UInt64(max(0, v))
    }
    static func time(_ ticks: UInt64) -> CMTime { CMTime(value: CMTimeValue(ticks), timescale: 27_000_000) }

    func chunk(arrivalUs: UInt64, bytes: Int, pcr27: UInt64?) {
        inputLog?("chunk,\(arrivalUs),\(bytes),\(pcr27.map(String.init) ?? "")")
        zm_lb_on_chunk(p, arrivalUs, UInt32(clamping: bytes), pcr27 != nil, pcr27 ?? 0)
    }
    func register(track: UInt32) {
        inputLog?("register,\(Self.nowUs()),\(track),")
        zm_lb_register_track(p, track)
    }
    func unregister(track: UInt32) {
        inputLog?("unregister,\(Self.nowUs()),\(track),")
        zm_lb_unregister_track(p, track)
    }
    func media(track: UInt32, end: CMTime) {
        let now = Self.nowUs(), e = Self.ticks(end)
        inputLog?("media,\(now),\(track),\(e)")
        zm_lb_on_track_media(p, now, track, e)
    }
    func tick(playback: CMTime?) {
        let now = Self.nowUs(), pos = playback.map(Self.ticks)
        inputLog?("tick,\(now),\(pos != nil ? 1 : 0),\(pos.map(String.init) ?? "")")
        zm_lb_on_tick(p, now, pos != nil, pos ?? 0)
    }

    enum Hint: UInt32 { case inputDegraded = 1, inputRecovered, syncLoss, pcrDiscontinuity, sourceEnded, sourceError, reconnected }
    func hint(_ h: Hint) {
        let now = Self.nowUs()
        inputLog?("hint,\(now),\(h.rawValue),")
        _ = zm_lb_on_hint(p, now, h.rawValue)
    }

    /// Decisions since the last call, in order.
    func decisions() -> [Decision] {
        var out: [Decision] = []
        var e = zm_lb_event()
        while zm_lb_poll(p, &e) {
            switch e.kind {
            case 1: out.append(.start(Self.time(e.media_27mhz)))
            case 2: out.append(.pause(holdAt: Self.time(e.media_27mhz), starvingTrack: e.track_valid == 1 ? e.track : nil))
            case 3: out.append(.resume(Self.time(e.media_27mhz)))
            default: break   // target changed / over max / rebaselined / dropped: informational
            }
        }
        return out
    }

    var stats: Stats {
        var s = zm_lb_stats()
        _ = zm_lb_get_stats(p, &s)
        return Stats(state: s.state, leadUs: s.lead_us, targetUs: s.target_us, stalls: s.stalls,
                     limitingTrack: s.limiting_valid == 1 ? s.limiting_track : nil)
    }

    var memory: (peak: UInt64, age: UInt64) {
        var a: UInt64 = 0, b: UInt64 = 0
        _ = zm_lb_snapshot(p, &a, &b)
        return (a, b)
    }
}
