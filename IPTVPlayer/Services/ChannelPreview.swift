import Foundation
import Observation
import ZenithMedia

/// The minimum a live preview needs from a player. `PlayerController` is the
/// real implementation on Apple TV; tests use a recorder.
protocol PreviewPlaying {
    func play(url: URL)
    func stop()
}

#if os(tvOS)
extension PlayerController: @MainActor PreviewPlaying {
    func play(url: URL) {
        play(url: url, credential: AuthorizedFetcher.streamCredential(for: url))
    }
}
#endif

/// Drives the channel-grid preview (Apple TV). Focus rests on a tile for the
/// dwell before that channel tunes, so scrolling past tiles does not tune
/// each one. The same player is handed to full screen unchanged, so
/// selecting the previewed channel never reconnects; the grid owns exactly
/// one player and one stream for its whole lifetime.
@MainActor @Observable
final class ChannelPreview {
    /// The channel wired to the player (or about to be). nil: nothing tuned.
    private(set) var channel: Channel?
    /// The previewed channel's id (cheap to observe in views).
    var channelID: String? { channel?.id }
    /// Full screen owns the player: focus changes behind it are ignored.
    private(set) var isFullScreen = false
    @ObservationIgnored private(set) var player: PreviewPlaying
    /// `player` as the real controller, for the views that draw it.
    @ObservationIgnored private(set) var controller: PlayerController?
    /// A full-screen channel the app stopped underneath, to start again.
    @ObservationIgnored private var restoringChannel: Channel?
    @ObservationIgnored private var pending: Channel?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private let dwell: Duration

    init(dwell: Duration, player: @MainActor @autoclosure @escaping () -> PreviewPlaying) {
        self.dwell = dwell
        let player = player()
        self.player = player
        self.controller = player as? PlayerController
    }

    /// The Siri Remote focus landed on `channel`'s tile.
    func focus(_ channel: Channel) {
        guard !isFullScreen, channel.id != self.channel?.id else { return }
        if pending?.id == channel.id { return }
        pending = channel
        dwellTask?.cancel()
        dwellTask = Task { [weak self, dwell] in
            do { try await Task.sleep(for: dwell) } catch { return }
            guard let self else { return }
            self.tune(channel)
        }
    }

    /// The grid page went away: drop the preview. A pending tune is cancelled.
    func leave() {
        pending = nil
        dwellTask?.cancel()
        dwellTask = nil
        guard channel != nil || !isFullScreen else { return }
        channel = nil
        isFullScreen = false
        player.stop()
    }

    /// Whether the running stream is exactly this channel.
    func isPlaying(_ channel: Channel) -> Bool {
        channel.id == self.channel?.id
    }

    /// Full screen takes over the player. It is already on `channel` when that
    /// is the preview, else it is tuned there; either way no second stream.
    func beginFullScreen(playing channel: Channel) {
        isFullScreen = true
        pending = nil
        dwellTask?.cancel()
        dwellTask = nil
        if !isPlaying(channel) { tune(channel) }
    }

    /// Kept for the preview contract: full screen takes the running player.
    func beginFullScreen() {
        isFullScreen = true
        pending = nil
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// Full screen closed on `nowPlaying` (nil: nothing was playing), which is
    /// still running. That channel becomes the preview and is not re-tuned.
    func endFullScreen(nowPlaying: Channel?) {
        guard isFullScreen else { return }
        isFullScreen = false
        channel = nowPlaying
    }

    /// Full screen closed after its player stopped (app went to background
    /// there and did not resume): `nowPlaying` is the channel to tune again.
    func endFullScreen(nowPlaying: Channel?, stopped: Bool) {
        endFullScreen(nowPlaying: stopped ? nil : nowPlaying)
        restoringChannel = stopped ? nowPlaying : nil
    }

    /// Playback should resume (app came back). On the grid that is the channel
    /// full screen left stopped, else the focused channel; both tune at once.
    /// In full screen the player view resumes its own channel.
    func resumed(focus channel: Channel?) {
        guard !isFullScreen else { return }
        if let restoring = restoringChannel {
            restoringChannel = nil
            tune(restoring, evenIfCurrent: true)
            return
        }
        guard let channel else { return }
        tune(channel)
    }

    private func tune(_ channel: Channel, evenIfCurrent: Bool = false) {
        pending = nil
        dwellTask = nil
        if !evenIfCurrent, channel.id == self.channel?.id { return }
        self.channel = channel
        player.play(url: channel.streamURL)
    }
}
