import Foundation
import Observation

struct SignInRequest: Equatable {
    let origin: Origin
    let challenge: AuthChallenge?
    let rejected: Bool
}

@MainActor @Observable
final class PlaylistService {

    private(set) var channels: [Channel] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// XMLTV guide from the playlist header (url-tvg); nil if the playlist has none.
    private(set) var guideURL: URL?
    /// No playlist configured yet: the app shows setup instead of channels.
    private(set) var needsSetup = false
    private(set) var signIn: SignInRequest?

    private let settingsStore: SettingsStore
    private let fetcher: AuthorizedFetcher
    private let retryDelay: Duration
    private var retryTask: Task<Void, Never>?

    init(settingsStore: SettingsStore, fetcher: AuthorizedFetcher = .shared, retryDelay: Duration = .seconds(30)) {
        self.settingsStore = settingsStore
        self.fetcher = fetcher
        self.retryDelay = retryDelay
    }

    func loadPlaylist() async {
        retryTask?.cancel()
        retryTask = nil

        errorMessage = nil
        signIn = nil
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
        } catch FetchError.unauthorized(let challenge, let origin, let rejected) {
            signIn = SignInRequest(origin: origin, challenge: challenge, rejected: rejected)
            channels = []
            guideURL = nil
        } catch FetchError.forbidden {
            errorMessage = "This server does not allow access."
            channels = []
            guideURL = nil
        } catch FetchError.http(let status) {
            errorMessage = "The server returned an error (HTTP \(status))."
            channels = []
            guideURL = nil
            if status >= 500 || status == 408 || status == 429 {
                scheduleRetry()
            }
        } catch let urlError as URLError {
            errorMessage = urlError.localizedDescription
            channels = []
            guideURL = nil
            scheduleRetry()
        } catch {
            errorMessage = error.localizedDescription
            channels = []
            guideURL = nil
        }

        isLoading = false
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.retryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.retryTask = nil
            await self.loadPlaylist()
        }
    }

    private func fetchPlaylistText() async throws -> String {
        guard let url = URL(string: settingsStore.playlistURL) else {
            throw URLError(.badURL)
        }
        let (data, _) = try await fetcher.data(from: Self.requestURL(for: url))
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        return text
    }

    /// The player plays raw MPEG-TS only, so ask for TS stream URLs:
    /// zenith hands out HLS (m3u8) to clients outside the LAN otherwise.
    /// An explicit format in the configured URL is left alone.
    nonisolated static func requestURL(for url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.queryItems ?? []
        guard !items.contains(where: { $0.name == "format" }) else { return url }
        items.append(URLQueryItem(name: "format", value: "ts"))
        c.queryItems = items
        return c.url ?? url
    }
}
