import Foundation
import Network
import Observation

struct DiscoveredServer {
    let name: String
    let playlistURL: String
}

@Observable
final class ZenithDiscoveryService {

    private(set) var pendingDiscovery: DiscoveredServer? = nil

    private var browser: NWBrowser?
    private let settingsStore: SettingsStore
    private var dismissedURLs: Set<String>

    private static let dismissedKey = "dismissedServerURLs"

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let arr = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        self.dismissedURLs = Set(arr)
    }

    func start() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_zenith._tcp", domain: "local.")
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                if self.tryApply(result) { break }
            }
        }

        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[ZenithDiscovery] browser error: \(error)")
            }
        }

        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    func accept() {
        guard let server = pendingDiscovery else { return }
        applyDiscovery(server)
        pendingDiscovery = nil
    }

    func dismiss() {
        guard let server = pendingDiscovery else { return }
        dismissedURLs.insert(server.playlistURL)
        saveDismissed()
        pendingDiscovery = nil
    }

    // MARK: - Testable helpers

    #if DEBUG
    func simulatePending(_ server: DiscoveredServer) {
        pendingDiscovery = server
    }

    func isDismissed(_ playlistURL: String) -> Bool {
        dismissedURLs.contains(playlistURL)
    }
    #endif

    // MARK: - Private

    /// Server from a `_zenith._tcp` TXT record. Only the playlist is needed:
    /// the guide comes from its url-tvg header.
    static func server(fromTXT txt: [String: String]) -> DiscoveredServer? {
        guard let baseURL = txt["url"], !baseURL.isEmpty else { return nil }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        func join(_ path: String) -> String { base + (path.hasPrefix("/") ? path : "/\(path)") }
        return DiscoveredServer(name: txt["name"] ?? base,
                                playlistURL: join(txt["playlist"] ?? "/playlist.m3u"))
    }

    @discardableResult
    private func tryApply(_ result: NWBrowser.Result) -> Bool {
        guard case .bonjour(let record) = result.metadata else { return false }

        var txt = [String: String]()
        for (key, entry) in record {
            if case .string(let value) = entry { txt[key] = value }
        }

        guard let server = Self.server(fromTXT: txt) else { return false }
        let playlistURL = server.playlistURL

        // Case 1: matches current config → no-op
        if settingsStore.playlistURL == playlistURL {
            DispatchQueue.main.async { self.stop() }
            return true
        }

        // Case 2: previously dismissed → skip
        if dismissedURLs.contains(playlistURL) {
            DispatchQueue.main.async { self.stop() }
            return true
        }

        // Case 3: nothing configured yet → auto-apply, no prompt
        if !settingsStore.isConfigured {
            applyDiscovery(server)
            DispatchQueue.main.async { self.stop() }
            print("[ZenithDiscovery] auto-applied: \(server.name)")
            return true
        }

        // Case 4: differs from configured → prompt user
        pendingDiscovery = server
        DispatchQueue.main.async { self.stop() }
        print("[ZenithDiscovery] pending user decision: \(server.name)")
        return true
    }

    private func applyDiscovery(_ server: DiscoveredServer) {
        settingsStore.playlistURL = server.playlistURL
        print("[ZenithDiscovery] applied: \(server.name)")
    }

    private func saveDismissed() {
        UserDefaults.standard.set(Array(dismissedURLs), forKey: Self.dismissedKey)
    }
}
