#if os(tvOS)
import SwiftUI

struct CountrySelectionView: View {
    var playlistService: PlaylistService
    var settingsStore: SettingsStore
    var discoveryService: ZenithDiscoveryService
    var epgService: EPGService

    @State private var showSettings = false

    private var groups: [String] {
        var seen = Set<String>()
        return playlistService.channels.compactMap { $0.group }.filter { seen.insert($0).inserted }
    }

    private func flag(for group: String) -> String {
        GroupFlag.emoji(for: group, channels: playlistService.channels.filter { $0.group == group }) ?? "\u{1F3F3}\u{FE0F}"
    }

    private func channels(for group: String) -> [Channel] {
        playlistService.channels.filter { $0.group == group }
    }

    var body: some View {
        NavigationStack {
            Group {
                if playlistService.isLoading {
                    ProgressView("Loading channels...")
                } else if playlistService.needsSetup {
                    SetupView(settingsStore: settingsStore)
                } else if let error = playlistService.errorMessage, playlistService.channels.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await playlistService.loadPlaylist() }
                        }
                    }
                } else {
                    HStack(spacing: 80) {
                        ForEach(groups, id: \.self) { group in
                            NavigationLink {
                                ChannelGridView(
                                    channels: channels(for: group),
                                    settingsStore: settingsStore,
                                    playlistService: playlistService,
                                    title: group,
                                    epgService: epgService
                                )
                            } label: {
                                VStack(spacing: 20) {
                                    Text(flag(for: group))
                                        .font(.system(size: 120))
                                    Text(group)
                                        .font(.title3)
                                }
                                .padding(40)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Zenith Player")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settingsStore: settingsStore) {
                Task { await playlistService.loadPlaylist() }
            }
        }
        .alert(
            "Zenith Server Found",
            isPresented: Binding(
                get: { discoveryService.pendingDiscovery != nil },
                set: { if !$0 { discoveryService.dismiss() } }
            ),
            presenting: discoveryService.pendingDiscovery
        ) { server in
            Button("Switch") {
                discoveryService.accept()
            }
            Button("Not Now", role: .cancel) { }
        } message: { server in
            Text("\(server.name) — \(server.playlistURL)")
        }
        .task {
            await playlistService.loadPlaylist()
        }
        .onChange(of: settingsStore.playlistURL) {
            Task { await playlistService.loadPlaylist() }
        }
    }
}
#endif
