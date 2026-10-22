import SwiftUI

@main
struct IPTVPlayerApp: App {
    @State private var settingsStore: SettingsStore
    @State private var playlistService: PlaylistService
    @State private var discoveryService: ZenithDiscoveryService
    @State private var epgService = EPGService()

    init() {
        let settings = SettingsStore()
        _settingsStore = State(initialValue: settings)
        _playlistService = State(initialValue: PlaylistService(settingsStore: settings))
        _discoveryService = State(initialValue: ZenithDiscoveryService(settingsStore: settings))
    }

    var body: some Scene {
        windowGroupWithPlatformContent
        #if os(macOS)
        settingsScene
        #endif
    }

    private var windowGroupWithPlatformContent: some Scene {
        WindowGroup {
            Group {
                #if os(tvOS)
                CountrySelectionView(
                    playlistService: playlistService,
                    settingsStore: settingsStore,
                    discoveryService: discoveryService,
                    epgService: epgService
                )
                #else
                iPadRootView(
                    playlistService: playlistService,
                    settingsStore: settingsStore,
                    discoveryService: discoveryService,
                    epgService: epgService
                )
                #endif
            }
            .onAppear {
                discoveryService.start()
            }
            .onChange(of: playlistService.guideURL, initial: true) { _, url in
                if let url { epgService.startAutoRefresh(from: url) } else { epgService.stopAutoRefresh() }
            }
            .onDisappear {
                discoveryService.stop()
                epgService.stopAutoRefresh()
            }
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Playlist") {
                    Task { await playlistService.loadPlaylist() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
    }

    #if os(macOS)
    private var settingsScene: some Scene {
        Settings {
            SettingsView(settingsStore: settingsStore) {
                Task { await playlistService.loadPlaylist() }
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }
    #endif
}
