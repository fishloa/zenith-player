import Foundation
import Observation

@Observable
final class SettingsStore {
    private static let playlistURLKey = "playlistURL"
    private let secrets: SecretStore
    let credentials: CredentialStore

    var playlistURL: String {
        didSet {
            guard playlistURL != oldValue else { return }
            let trimmed = playlistURL.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                _ = secrets.set(nil, for: Self.playlistURLKey)
            } else {
                _ = secrets.set(Data(playlistURL.utf8), for: Self.playlistURLKey)
            }
        }
    }

    init(secrets: SecretStore = KeychainSecretStore(), arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.secrets = secrets
        credentials = CredentialStore(secrets: secrets)
        var url = secrets.data(for: Self.playlistURLKey).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if url.isEmpty, let legacy = Self.legacyPlaylistURL() {
            if secrets.set(Data(legacy.utf8), for: Self.playlistURLKey) {
                let readBack = secrets.data(for: Self.playlistURLKey).map { String(decoding: $0, as: UTF8.self) }
                if readBack == legacy {
                    Self.removeLegacyPlaylistURL()
                }
            }
            url = legacy
        }
        if let i = arguments.firstIndex(of: "-zenithPlaylist"), arguments.indices.contains(i + 1) {
            url = arguments[i + 1]
        }
        playlistURL = url
    }

    private static func legacyPlaylistURL() -> String? {
        let kvs = NSUbiquitousKeyValueStore.default
        let url = kvs.string(forKey: playlistURLKey) ?? UserDefaults.standard.string(forKey: playlistURLKey)
        return url?.isEmpty == false ? url : nil
    }

    private static func removeLegacyPlaylistURL() {
        let kvs = NSUbiquitousKeyValueStore.default
        kvs.removeObject(forKey: playlistURLKey)
        kvs.synchronize()
        UserDefaults.standard.removeObject(forKey: playlistURLKey)
    }

    @discardableResult func setPlaylist(_ text: String) -> Bool {
        let (url, credential) = Credential.split(text.trimmingCharacters(in: .whitespaces))
        if let credential, let origin = URL(string: url).flatMap(Origin.init) {
            credentials.set(credential, for: origin)
        }
        let changed = url != playlistURL
        playlistURL = url
        return changed
    }

    var playlistOrigin: Origin? { URL(string: playlistURL).flatMap(Origin.init) }

    var isConfigured: Bool { !playlistURL.trimmingCharacters(in: .whitespaces).isEmpty }
}
