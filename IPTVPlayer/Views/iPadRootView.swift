#if os(iOS) || os(macOS)
import SwiftUI

struct iPadRootView: View {
    var playlistService: PlaylistService
    var settingsStore: SettingsStore
    var discoveryService: ZenithDiscoveryService
    var epgService: EPGService

    @State private var showSettings = false
    @State private var path: [String] = []
    @State private var launchGroupShown = false

    #if os(macOS)
    @State private var selectedGroup: String?
    #endif

    private static let launchGroupID: String? = LaunchArguments.value(after: "-zenithOpenGroup")

    private var groups: [String] {
        var seen = Set<String>()
        return playlistService.channels.compactMap { $0.group }.filter { seen.insert($0).inserted }
    }

    private func flag(for group: String) -> String {
        GroupFlag.emoji(for: group, channels: playlistService.channels.filter { $0.group == group }) ?? "\u{1F3F3}\u{FE0F}"
    }

    private func channels(for group: String) -> [Channel] {
        playlistService.channels
            .filter { $0.group == group }
            .sorted {
                if $0.channelNumber != $1.channelNumber {
                    return $0.channelNumber < $1.channelNumber
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        #if os(macOS)
        rootModifiers(
            NavigationSplitView {
                sidebar
                    .navigationTitle("Zenith")
                    .frame(minWidth: 200)
            } detail: {
                if let group = selectedGroup, groups.contains(group) {
                    ChannelGridView(
                        channels: channels(for: group),
                        settingsStore: settingsStore,
                        playlistService: playlistService,
                        title: group,
                        epgService: epgService
                    )
                } else {
                    Text("Select a country")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
        )
        #else
        rootModifiers(
            NavigationStack(path: $path) {
                withPlaceholder {
                    List(groups, id: \.self) { group in
                        NavigationLink(value: group) {
                            Label {
                                Text(group)
                                    .font(.title3)
                            } icon: {
                                Text(flag(for: group))
                                    .font(.title2)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
                .navigationTitle("Zenith")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
                .navigationDestination(for: String.self) { group in
                    ChannelGridView(
                        channels: channels(for: group),
                        settingsStore: settingsStore,
                        playlistService: playlistService,
                        title: group,
                        epgService: epgService
                    )
                }
                .onChange(of: playlistService.channels.map(\.id)) { _, _ in
                    if !launchGroupShown, let group = Self.launchGroupID, groups.contains(group) {
                        launchGroupShown = true
                        path = [group]
                    }
                }
            }
        )
        #endif
    }

    /// Modifiers shared by both platform roots (settings sheet, discovery alert, initial load).
    private func rootModifiers(_ content: some View) -> some View {
        content
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

    #if os(macOS)
    @ViewBuilder
    private var sidebar: some View {
        withPlaceholder {
            List(groups, id: \.self, selection: $selectedGroup) { group in
                Label {
                    Text(group)
                } icon: {
                    Text(flag(for: group))
                }
            }
        }
    }
    #endif

    /// Shared loading/error/content scaffolding for both platform roots.
    @ViewBuilder
    private func withPlaceholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if playlistService.isLoading {
            ProgressView("Loading channels...")
        } else if let request = playlistService.signIn {
            SignInView(request: request, settingsStore: settingsStore) {
                Task { await playlistService.loadPlaylist() }
            }
        } else if let request = epgService.signIn {
            SignInView(request: request, settingsStore: settingsStore) {
                Task {
                    if let url = playlistService.guideURL {
                        await epgService.load(from: url)
                    }
                }
            }
        } else if playlistService.needsSetup {
            SetupView(settingsStore: settingsStore)
        } else if let error = playlistService.errorMessage, playlistService.channels.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await playlistService.loadPlaylist() }
                }
            }
            .padding()
        } else {
            content()
        }
    }
}
#endif
