import SwiftUI
import ZenithMedia

/// A ButtonStyle that renders nothing — no card lift, no highlight — while still
/// being focusable and responding to the Siri Remote select button.
private struct _InvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct PlayerView: View {
    let channel: Channel
    let channels: [Channel]
    let epgURL: URL?
    let epgService: EPGService

    /// Owns demux → decode → deinterlace → render, buffering, stall detection
    /// and reconnect-with-back-off (ZenithMedia). Apple TV's full screen is
    /// handed the grid preview's player rather than creating its own.
    @State private var player: PlayerController
    @State private var currentChannel: Channel
    /// A shared controller is the grid preview's: it outlives this view and
    /// keeps playing on its own, so leaving must not stop it.
    private let usesPreviewPlayer: Bool
    /// Told whenever the channel changes, so the grid knows what ended up
    /// playing. Needed when the player is shared with the grid preview's.
    private let onChannelChange: ((Channel) -> Void)?
    @State private var showEPG = false
    @Environment(\.scenePhase) private var scenePhase

    #if os(macOS)
    @State private var sleepActivity: NSObjectProtocol?
    #endif

    /// Show only channels in the same group as the current channel. Fall back to all if no group.
    private var epgChannels: [Channel] {
        guard let group = currentChannel.group else { return channels }
        let filtered = channels.filter { $0.group == group }
        return filtered.isEmpty ? channels : filtered
    }

    init(channel: Channel, channels: [Channel], epgURL: URL?, epgService: EPGService,
         sharingPlayer player: PlayerController? = nil,
         onChannelChange: ((Channel) -> Void)? = nil) {
        self.channel = channel
        self.channels = channels
        self.epgURL = epgURL
        self.epgService = epgService
        _currentChannel = State(initialValue: channel)
        if let player {
            _player = State(initialValue: player)
        } else {
            // The tvOS upscale target defaults in PlayerPolicy (the screen's
            // native size), so every player gets it without a caller setting it.
            _player = State(initialValue: PlayerController())
        }
        self.usesPreviewPlayer = player != nil
        self.onChannelChange = onChannelChange
    }

    #if os(iOS) || os(macOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch player.phase {
            case .loading:
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Starting stream…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            case .playing, .buffering:
                playerLayer
                    .ignoresSafeArea()
                    .overlay {
                        if case .buffering(let msg) = player.phase {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                    .tint(.white)
                                if let msg {
                                    Text(msg)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                            .padding(24)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if showEPG {
                            EPGOverlayView(
                                channels: epgChannels,
                                currentChannel: currentChannel,
                                epgService: epgService,
                                onSwitch: switchChannel,
                                onDismiss: { showEPG = false }
                            )
                            .transition(.move(edge: .bottom))
                        } else {
                            #if os(tvOS)
                            Button(action: { showEPG = true }) {
                                Color.clear
                            }
                            .buttonStyle(_InvisibleButtonStyle())
                            // Long-press select: choose the audio track.
                            .contextMenu { audioMenuItems }
                            #endif
                        }
                    }
                    #if os(iOS) || os(macOS)
                    .onTapGesture { showEPG.toggle() }
                    #endif
            case .reconnecting(let attempt):
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(2)
                    Text("Reconnecting… (attempt \(attempt))")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("Stream unavailable")
                        .font(.headline)
                }
            }
        }
        #if os(iOS) || os(macOS)
        .safeAreaInset(edge: .top) {
            HStack {
                Button {
                    player.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray.opacity(0.6))
                }
                Spacer()
                if player.audioTracks.count > 1 {
                    Menu {
                        audioMenuItems
                    } label: {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray.opacity(0.6))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Audio track")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        #endif
        .task(id: currentChannel.id) {
            // A shared player is the grid's: it was tuned there before this
            // view opened, so nothing starts here unless it is idle (app just
            // came back) or the switch below changed the channel.
            if usesPreviewPlayer, player.phase != .loading {
                print("[PlayerView] reuse running stream \(currentChannel.streamURL)")
                return
            }
            let url = currentChannel.streamURL
            print("[PlayerView] play \(url)")
            player.play { HTTPByteSource(url: url) }
        }
        .onAppear {
            #if os(iOS) || os(tvOS)
            UIApplication.shared.isIdleTimerDisabled = true
            #elseif os(macOS)
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Playing video"
            )
            #endif
        }
        .onDisappear {
            // A shared player belongs to the grid, which stops and restarts it
            // on its own terms.
            if !usesPreviewPlayer { player.stop() }
            #if os(iOS) || os(tvOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #elseif os(macOS)
            if let activity = sleepActivity {
                ProcessInfo.processInfo.endActivity(activity)
                sleepActivity = nil
            }
            #endif
        }
        .onChange(of: player.stats.rebuffers) { _, _ in PlaybackLog.stall(currentChannel.id, player.stats) }
        .onChange(of: player.stats.restarts) { _, _ in PlaybackLog.stall(currentChannel.id, player.stats, kind: "restart") }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS) || os(tvOS)
            // Background stops playback; returning restarts at the live edge.
            switch newPhase {
            case .background:
                player.stop()
            case .active:
                // Coming back, whatever was playing resumes at the live edge:
                // full screen's own channel, shared player or not.
                if player.phase == .loading {
                    let url = currentChannel.streamURL
                    player.play { HTTPByteSource(url: url) }
                }
            default: break
            }
            #endif
        }
        .onChange(of: showEPG) { _, newValue in
            if newValue {
                if let epgURL { Task { await epgService.loadIfStale(from: epgURL) } }
            }
        }
    }

    /// Audio tracks of the current channel: Automatic, then each track; the
    /// playing one is checked.
    @ViewBuilder private var playerLayer: some View {
        #if os(tvOS)
        PlayerLayerView(renderer: player.renderer, frameRate: player.outputFrameRate,
                        matchesDisplayMode: !usesPreviewPlayer)
        #else
        PlayerLayerView(renderer: player.renderer, frameRate: player.outputFrameRate)
        #endif
    }

    @ViewBuilder private var audioMenuItems: some View {
        Section("Audio") {
            Button {
                player.selectAudio(nil)
            } label: {
                if player.chosenAudioTrack == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            ForEach(player.audioTracks) { t in
                Button {
                    player.selectAudio(t.id)
                } label: {
                    if player.chosenAudioTrack == t.id || (player.chosenAudioTrack == nil && player.playingAudioTrack == t.id) {
                        Label(t.label, systemImage: player.chosenAudioTrack == t.id ? "checkmark" : "speaker.wave.2")
                    } else {
                        Text(t.label)
                    }
                }
            }
        }
    }

    private func switchChannel(to newChannel: Channel) {
        showEPG = false
        currentChannel = newChannel
        onChannelChange?(newChannel)
        // task(id: currentChannel.id) starts the new channel; play() stops the old one first.
    }
}

/// One line per stall or restart in Library/Caches/playback.log, so an
/// intermittent problem on the TV can be read back later (devicectl copy)
/// without interrupting playback. Kept to the last ~256 KB.
enum PlaybackLog {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("playback.log")
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func stall(_ channel: String, _ s: PlayerStats, kind: String = "stall") {
        let line = "\(stamp.string(from: Date())) \(kind) \(channel) rebuffers=\(s.rebuffers) restarts=\(s.restarts) "
            + "nodata=\(s.starvedNoData) withdata=\(s.starvedWithData) "
            + String(format: "max_gap=%.2fs", s.maxChunkGap)
            + " pause=[\(s.lastPauseInfo?.split(separator: "|").last.map(String.init) ?? "")]\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            if let end = try? h.seekToEnd(), end > 256 * 1024 { try? h.truncate(atOffset: 0) }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
