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

    /// No built-in server: a fresh install has no playlist and asks for one.
    func testFreshInstallHasNoPlaylist() {
        let store = SettingsStore()
        XCTAssertEqual(store.playlistURL, "")
        XCTAssertFalse(store.isConfigured)
    }

    func testUpdatePlaylistURL() {
        let store = SettingsStore()
        store.playlistURL = "http://192.168.1.50/playlist.m3u"
        XCTAssertEqual(store.playlistURL, "http://192.168.1.50/playlist.m3u")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "playlistURL"), "http://192.168.1.50/playlist.m3u")
    }

    func testConfiguredOncePlaylistSet() {
        let store = SettingsStore()
        store.playlistURL = "http://other.server/playlist.m3u"
        XCTAssertTrue(store.isConfigured)
    }

    func testBlankPlaylistIsNotConfigured() {
        let store = SettingsStore()
        store.playlistURL = "   "
        XCTAssertFalse(store.isConfigured)
    }
}
