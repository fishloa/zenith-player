import Foundation
@testable import IPTVPlayer

final class InMemorySecretStore: SecretStore {
    private(set) var items: [String: Data] = [:]
    var failWrites = false

    func data(for key: String) -> Data? { items[key] }

    func set(_ data: Data?, for key: String) -> Bool {
        if failWrites { return false }
        if data == nil { items.removeValue(forKey: key) } else { items[key] = data }
        return true
    }
}

extension SettingsStore {
    static func testing(_ secrets: SecretStore = InMemorySecretStore()) -> SettingsStore {
        SettingsStore(secrets: secrets, arguments: [])
    }
}
