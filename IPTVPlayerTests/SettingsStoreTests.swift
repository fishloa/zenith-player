import XCTest
@testable import IPTVPlayer

final class SettingsStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "playlistURL")
        UserDefaults.standard.removeObject(forKey: "epgURL")
        UserDefaults.standard.synchronize()

        // Also clear iCloud store
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "playlistURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "epgURL")
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: "playlistURL")
        UserDefaults.standard.removeObject(forKey: "epgURL")
        UserDefaults.standard.synchronize()

        NSUbiquitousKeyValueStore.default.removeObject(forKey: "playlistURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "epgURL")
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    func testFreshInstallHasNoPlaylist() {
        let store = SettingsStore.testing()
        XCTAssertEqual(store.playlistURL, "")
        XCTAssertFalse(store.isConfigured)
    }

    func testPlaylistURLIsKeptInTheSecretStoreOnly() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore.testing(secrets)
        store.playlistURL = "https://tv.example.org/playlist.m3u?t=secret"
        XCTAssertEqual(SettingsStore.testing(secrets).playlistURL, "https://tv.example.org/playlist.m3u?t=secret")
        XCTAssertNil(UserDefaults.standard.string(forKey: "playlistURL"))
        XCTAssertNil(NSUbiquitousKeyValueStore.default.string(forKey: "playlistURL"))
    }

    func testLegacyPlaylistURLMovesToKeychain() {
        NSUbiquitousKeyValueStore.default.set("https://old.example.org/playlist.m3u", forKey: "playlistURL")
        UserDefaults.standard.set("https://old.example.org/playlist.m3u", forKey: "playlistURL")
        let secrets = InMemorySecretStore()
        let store = SettingsStore.testing(secrets)
        XCTAssertEqual(store.playlistURL, "https://old.example.org/playlist.m3u")
        XCTAssertNil(UserDefaults.standard.string(forKey: "playlistURL"))
        XCTAssertNil(NSUbiquitousKeyValueStore.default.string(forKey: "playlistURL"))
        XCTAssertEqual(SettingsStore.testing(secrets).playlistURL, "https://old.example.org/playlist.m3u")
    }

    func testSetPlaylistSplitsCredentialsByOrigin() throws {
        let store = SettingsStore.testing()
        store.setPlaylist("  https://u:p@tv.example.org/playlist.m3u ")
        XCTAssertEqual(store.playlistURL, "https://tv.example.org/playlist.m3u")
        let origin = try XCTUnwrap(store.playlistOrigin)
        XCTAssertEqual(store.credentials.credential(for: origin), .password(user: "u", password: "p"))
        XCTAssertNil(store.credentials.credential(for: try XCTUnwrap(Origin(URL(string: "https://other.example.org")!))))
    }

    func testLaunchArgumentSetsPlaylist() {
        let store = SettingsStore(secrets: InMemorySecretStore(), arguments: ["app", "-zenithPlaylist", "http://10.0.0.2:8099/playlist.m3u"])
        XCTAssertEqual(store.playlistURL, "http://10.0.0.2:8099/playlist.m3u")
    }

    func testLaunchWritesNothingWhenNothingChanged() {
        let secrets = InMemorySecretStore()
        _ = SettingsStore.testing(secrets)
        XCTAssertTrue(secrets.items.isEmpty)
    }

    func testLegacyIsKeptWhenTheKeychainWriteFails() {
        UserDefaults.standard.set("https://old.example.org/playlist.m3u", forKey: "playlistURL")
        let secrets = InMemorySecretStore()
        secrets.failWrites = true
        let store = SettingsStore.testing(secrets)
        XCTAssertEqual(store.playlistURL, "https://old.example.org/playlist.m3u")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "playlistURL"), "https://old.example.org/playlist.m3u")
    }

    func testLaunchArgumentIsNotPersisted() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore(secrets: secrets, arguments: ["app", "-zenithPlaylist", "http://10.0.0.2:8099/playlist.m3u"])
        XCTAssertEqual(store.playlistURL, "http://10.0.0.2:8099/playlist.m3u")
        XCTAssertNil(secrets.data(for: "playlistURL"))
    }

    func testClearingThePlaylistDeletesTheItem() {
        let secrets = InMemorySecretStore()
        let store = SettingsStore.testing(secrets)
        store.playlistURL = "https://a.example.org/p.m3u"
        store.playlistURL = ""
        XCTAssertNil(secrets.data(for: "playlistURL"))
    }

    func testBlankPlaylistIsNotConfigured() {
        let store = SettingsStore.testing()
        store.playlistURL = "   "
        XCTAssertFalse(store.isConfigured)
    }
}


