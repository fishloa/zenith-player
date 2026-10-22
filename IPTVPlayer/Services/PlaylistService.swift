import Foundation
import Observation

@Observable
final class PlaylistService {

    private(set) var channels: [Channel] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// XMLTV guide from the playlist header (url-tvg); nil if the playlist has none.
    private(set) var guideURL: URL?
    /// No playlist configured yet: the app shows setup instead of channels.
    private(set) var needsSetup = false

    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func loadPlaylist() async {
        errorMessage = nil
        needsSetup = !settingsStore.isConfigured
        guard !needsSetup else {
            channels = []
            guideURL = nil
            return
        }
        isLoading = true

        do {
            let text = try await fetchPlaylistText()
            channels = M3UParser.parse(text)
            guideURL = URL(string: settingsStore.playlistURL).flatMap { M3UParser.guideURL(in: text, relativeTo: $0) }
            if channels.isEmpty {
                errorMessage = "No channels found in playlist."
            }
        } catch {
            errorMessage = error.localizedDescription
            channels = []
            guideURL = nil
        }

        isLoading = false
    }

    private func fetchPlaylistText() async throws -> String {
        guard let url = URL(string: settingsStore.playlistURL) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: Self.requestURL(for: url))
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    /// The player plays raw MPEG-TS only, so ask for TS stream URLs:
    /// zenith hands out HLS (m3u8) to clients outside the LAN otherwise.
    /// An explicit format in the configured URL is left alone.
    static func requestURL(for url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.queryItems ?? []
        guard !items.contains(where: { $0.name == "format" }) else { return url }
        items.append(URLQueryItem(name: "format", value: "ts"))
        c.queryItems = items
        return c.url ?? url
    }
}
