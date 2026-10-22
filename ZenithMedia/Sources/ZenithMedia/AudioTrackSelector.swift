/// Picks the audio track to play when a channel carries several.
///
/// 1. Exclude audio description and hard-of-hearing tracks (role from the
///    PMT via transmux: audio_type, supplementary audio descriptor, "qad").
/// 2. Rank the rest: more channels, then codec (E-AC-3 > AC-3 > AAC > MP2),
///    then nominal bitrate, then PMT order.
/// 3. If every track is excluded, take the first in PMT order.
public enum AudioTrackSelector {
    static func codecRank(_ c: Codec) -> Int {
        switch c {
        case .eac3: 4
        case .ac3: 3
        case .aac: 2
        case .mpegAudio: 1
        default: 0
        }
    }

    /// `tracks` in PMT order.
    public static func choose(_ tracks: [TrackInfo]) -> TrackInfo? {
        let playable = tracks.filter { codecRank($0.codec) > 0 }
        let eligible = playable.enumerated().filter { $0.element.role != .audioDescription && $0.element.role != .hearingImpaired }
        guard !eligible.isEmpty else { return playable.first }
        return eligible.max { a, b in
            let ka = (a.element.channels, codecRank(a.element.codec), a.element.bitrate, -a.offset)
            let kb = (b.element.channels, codecRank(b.element.codec), b.element.bitrate, -b.offset)
            return ka < kb
        }?.element
    }
}
