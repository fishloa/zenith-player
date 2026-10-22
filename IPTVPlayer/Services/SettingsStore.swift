import Foundation
import Observation

@Observable
final class SettingsStore {

    private static let playlistURLKey = "playlistURL"
    private let cloudStore = NSUbiquitousKeyValueStore.default

    var playlistURL: String {
        didSet {
            UserDefaults.standard.set(playlistURL, forKey: Self.playlistURLKey)
            cloudStore.set(playlistURL, forKey: Self.playlistURLKey)
            cloudStore.synchronize()
        }
    }

    init() {
        let cloudPlaylist = NSUbiquitousKeyValueStore.default.string(forKey: Self.playlistURLKey)
        let localPlaylist = UserDefaults.standard.string(forKey: Self.playlistURLKey)
        self.playlistURL = cloudPlaylist ?? localPlaylist ?? ""

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore
        )
    }

    @objc private func iCloudDidChange(_ notification: Notification) {
        guard let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
        if keys.contains(Self.playlistURLKey),
           let newValue = cloudStore.string(forKey: Self.playlistURLKey) {
            playlistURL = newValue
        }
    }

    /// No server is built in: until a playlist is set (typed in, or found
    /// on the network) the app shows setup. The guide URL is not a setting:
    /// it comes from the playlist's url-tvg.
    var isConfigured: Bool { !playlistURL.trimmingCharacters(in: .whitespaces).isEmpty }
}
