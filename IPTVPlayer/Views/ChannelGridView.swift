import SwiftUI
#if os(tvOS)
import ZenithMedia
#endif

struct ChannelGridView: View {
    var channels: [Channel]
    var settingsStore: SettingsStore
    var playlistService: PlaylistService
    var title: String
    var epgService: EPGService

    @State private var selectedChannel: Channel?

    #if os(tvOS)
    /// Apple TV: the focused tile tunes behind the grid after a short dwell.
    /// The grid's one player is handed to full screen and back, so a channel
    /// is never streamed twice and selecting the previewed one never re-tunes.
    /// Built lazily: a view value is re-created on every update, so its init
    /// must not build a player (renderer and display layer included).
    @State private var preview = PreviewStore()
    @FocusState private var focusedTile: String?
    /// Where focus returns when the cover closes: the channel that played full
    /// screen. Expecting it means a late focus report for any other tile
    /// cannot move the preview during the dismissal.
    @State private var focusAfterFullScreen: String?
    @Environment(\.scenePhase) private var scenePhase
    #endif

    #if os(tvOS)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 40), count: 4)
    private let gridSpacing: CGFloat = 40
    private let gridPadding: CGFloat = 60
    #elseif os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 20)]
    private let gridSpacing: CGFloat = 20
    private let gridPadding: CGFloat = 20
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var columns: [GridItem] {
        let count = sizeClass == .regular ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: 20), count: count)
    }
    private let gridSpacing: CGFloat = 20
    private let gridPadding: CGFloat = 20
    #endif

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(channels) { channel in
                    channelButton(channel)
                }
            }
            .padding(gridPadding)
        }
        #if os(tvOS)
        .onChange(of: scenePhase, resumePreview)
        #endif
        .navigationTitle(GroupFlag.emoji(for: title, channels: channels).map { "\($0)  \(title)" } ?? title)
        #if os(macOS)
        .sheet(item: $selectedChannel) { channel in
            PlayerView(
                channel: channel,
                channels: channels,
                epgURL: playlistService.guideURL,
                epgService: epgService
            )
            .frame(minWidth: 960, minHeight: 540)
        }
        #elseif os(tvOS)
        .background {
            PreviewVideo(preview: preview.preview)
        }
        .fullScreenCover(
            item: $selectedChannel,
            onDismiss: { endFullScreen() },
            content: fullScreenPlayer
        )
        .onDisappear {
            // Covers close before the grid appears again, so a grid that is
            // really gone (navigated back) is the one whose leave sticks.
            preview.leave()
        }
        .onAppear { gridShown() }
        .onChange(of: selectedChannel?.id, gridVisibility)
        .onChange(of: focusedTile) { _, id in preview.focus(id, channels: channels) }
        #else
        .fullScreenCover(item: $selectedChannel) { channel in
            PlayerView(
                channel: channel,
                channels: channels,
                epgURL: playlistService.guideURL,
                epgService: epgService
            )
        }
        #endif
    }

    private func channelButton(_ channel: Channel) -> some View {
        Button {
            select(channel)
        } label: {
            tile(for: channel)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(tvOS)
        .focused($focusedTile, equals: channel.id)
        #endif
    }

    /// Views follow the store: it owns the preview and bumps `changes` on
    /// every change. Off Apple TV there is nothing to preview.
    private func observePreview() -> Int {
        #if os(tvOS)
        preview.changes
        #else
        0
        #endif
    }

    @ViewBuilder private func tile(for channel: Channel) -> some View {
        let _ = observePreview()
        #if os(tvOS)
        ChannelTile(channel: channel, isPreviewing: preview.preview?.channel != nil)
        #else
        ChannelTile(channel: channel)
        #endif
    }

    #if os(tvOS)
    private func fullScreenPlayer(_ channel: Channel) -> PlayerView {
        PlayerView(
            channel: channel,
            channels: channels,
            epgURL: playlistService.guideURL,
            epgService: epgService,
            sharingPlayer: preview.preview?.controller,
            onChannelChange: onFullScreenChannelChange
        )
    }

    // ScenePhase overloads of onChange have the closure `Sendable`, which the
    // two-argument form does not allow with main-actor state; a method is.
    private func resumePreview(_ oldPhase: ScenePhase, _ phase: ScenePhase) {
        // A shared player stopped on background, so its phase says nothing.
        if phase == .active { preview.resume(focus: focusedTile, channels: channels) }
    }

    private func onFullScreenChannelChange(_ channel: Channel) {
        preview.fullScreenNowPlaying(channel)
    }

    /// The channel that played full screen keeps playing behind the grid;
    /// focus goes back to its tile so no other tile can tune it away.
    private func gridShown() {
        preview.gridShown()
        if let id = focusAfterFullScreen {
            focusAfterFullScreen = nil
            focusedTile = id
        }
    }

    /// The cover closed: the channel that played full screen keeps playing
    /// behind the grid, and focus returns to it so no other tile tunes.
    private func gridVisibility(_ closing: String?, _ closed: String?) {
        guard closing != nil, closed == nil else { return }
        gridShown()
    }

    private func select(_ channel: Channel) {
        // The grid's single player goes full screen, already on this channel
        // when it is the preview, else tuned there: never two streams.
        preview.beginFullScreen(playing: channel)
        preview.gridHidden()
        selectedChannel = channel
    }

    private func endFullScreen() {
        // PlayerView reports every switch, so the preview already knows what
        // played. The stream is not stopped: it continues behind the grid.
        if let playing = preview.endFullScreen(nowPlaying: preview.preview?.channel,
                                                stopped: preview.preview?.controller?.phase == .loading) {
            focusAfterFullScreen = playing.id
        }
        selectedChannel = nil
    }

    #else
    private func select(_ channel: Channel) {
        selectedChannel = channel
    }
    #endif
}

#if os(tvOS)
/// The grid page's preview, built the first time the page needs it (first
/// focus, or first frame), so view re-inits never build a player. A page
/// state keeps the same instance for its lifetime.
@MainActor @Observable
final class PreviewStore {
    private(set) var preview: ChannelPreview?
    /// Bumped on every change, so views depend on the store rather than on
    /// the preview's own observation.
    private(set) var changes = 0
    /// Whether the grid is showing (the full-screen cover hides it).
    private(set) var isShowing = true

    /// The page's preview, built on first use only.
    @discardableResult
    func ensure() -> ChannelPreview {
        if let preview { return preview }
        let created: ChannelPreview
        do {
            created = ChannelPreview(dwell: .milliseconds(600), player: PlayerController())
        }
        preview = created
        changes += 1
        return created
    }

    func focus(_ id: String?, channels: [Channel]) {
        // Focus reports racing the cover's transitions are not the viewer.
        guard isShowing, let id, let channel = channels.first(where: { $0.id == id }) else { return }
        ensure().focus(channel)
        changes += 1
    }

    /// Coming back to the app: tune the focused channel again at once.
    func resume(focus id: String?, channels: [Channel]) {
        guard let channel = id.flatMap({ id in channels.first { $0.id == id } }) else { return }
        ensure().resumed(focus: channel)
        changes += 1
    }

    func beginFullScreen(playing channel: Channel) {
        ensure().beginFullScreen(playing: channel)
        changes += 1
    }

    /// Full screen reports the channel it switched to.
    func fullScreenNowPlaying(_ channel: Channel) {
        preview?.endFullScreen(nowPlaying: channel)
        changes += 1
    }

    /// The cover closed. Returns the channel still playing behind the grid
    /// (nil when the player was stopped, e.g. the app backgrounded full
    /// screen: that channel is tuned again when the app comes back).
    func endFullScreen(nowPlaying channel: Channel?, stopped: Bool) -> Channel? {
        defer { changes += 1 }
        guard let preview, preview.isFullScreen else { return nil }
        preview.endFullScreen(nowPlaying: channel, stopped: stopped)
        return preview.channel
    }

    func leave() {
        preview?.leave()
        changes += 1
    }

    func gridHidden() {
        isShowing = false
        changes += 1
    }

    /// Back on the grid after full screen, which left its channel playing.
    func gridShown() {
        isShowing = true
        if let preview, preview.isFullScreen {
            preview.endFullScreen(nowPlaying: preview.channel)
        }
        changes += 1
    }
}

/// The previewed stream, full screen behind the grid. Never requests a
/// display mode: the refresh-rate switch blanks the screen for about a
/// second and is reserved for full screen.
private struct PreviewVideo: View {
    let preview: ChannelPreview?

    var body: some View {
        ZStack {
            Color.black
            if let controller = preview?.controller {
                PlayerLayerView(renderer: controller.renderer, matchesDisplayMode: false,
                                claimsLayer: !(preview?.isFullScreen ?? false))
                switch controller.phase {
                case .loading, .reconnecting:
                    ProgressView()
                        .scaleEffect(1.5)
                case .failed, .forbidden, .needsCredentials, .playing, .buffering:
                    EmptyView()
                }
            }
        }
        .accessibilityHidden(true)
    }
}
#endif
