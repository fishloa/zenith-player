import Foundation
import Security

protocol SecretStore: AnyObject {
    func data(for key: String) -> Data?
    @discardableResult func set(_ data: Data?, for key: String) -> Bool
}

final class KeychainSecretStore: SecretStore {
    private let service: String

    init(service: String = "zenith-player") { self.service = service }

    private func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
         kSecAttrSynchronizable: kCFBooleanTrue as Any]
    }

    func data(for key: String) -> Data? {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func set(_ data: Data?, for key: String) -> Bool {
        if data == nil {
            let status = SecItemDelete(query(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let attributes: [CFString: Any] = [kSecValueData: data as Any, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        let updateStatus = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }
}

final class CredentialStore {
    private let secrets: SecretStore

    init(secrets: SecretStore) { self.secrets = secrets }

    func credential(for origin: Origin) -> Credential? {
        secrets.data(for: key(origin)).flatMap { try? JSONDecoder().decode(Credential.self, from: $0) }
    }

    func set(_ credential: Credential?, for origin: Origin) {
        secrets.set(credential.flatMap { try? JSONEncoder().encode($0) }, for: key(origin))
    }

    private func key(_ origin: Origin) -> String { "credential \(origin)" }
}
