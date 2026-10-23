import XCTest
@testable import IPTVPlayer

final class ZenithDiscoveryServiceTests: XCTestCase {

    private static let dismissedKey = "dismissedServerURLs"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        UserDefaults.standard.removeObject(forKey: "playlistURL")
        UserDefaults.standard.removeObject(forKey: "epgURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "playlistURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "epgURL")
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: Self.dismissedKey)
        UserDefaults.standard.removeObject(forKey: "playlistURL")
        UserDefaults.standard.removeObject(forKey: "epgURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "playlistURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "epgURL")
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Only the playlist comes from the TXT record (the guide is its url-tvg).
    func testServerFromTXT() throws {
        let s = try XCTUnwrap(ZenithDiscoveryService.server(fromTXT: ["url": "https://tv.example/", "name": "Zenith"]))
        XCTAssertEqual(s.playlistURL, "https://tv.example/playlist.m3u")
        XCTAssertEqual(s.name, "Zenith")
        let t = try XCTUnwrap(ZenithDiscoveryService.server(fromTXT: ["url": "https://tv.example", "playlist": "p.m3u", "epg": "/x"]))
        XCTAssertEqual(t.playlistURL, "https://tv.example/p.m3u")
        XCTAssertNil(ZenithDiscoveryService.server(fromTXT: ["name": "no url"]))
    }

    func testPendingDiscoveryIsNilInitially() {
        let store = SettingsStore.testing()
        let svc = ZenithDiscoveryService(settingsStore: store)
        XCTAssertNil(svc.pendingDiscovery)
    }

    func testAcceptAppliesDiscoveryToSettingsStore() {
        let store = SettingsStore.testing()
        let svc = ZenithDiscoveryService(settingsStore: store)
        svc.simulatePending(DiscoveredServer(
            name: "TestServer",
            playlistURL: "https://other.server/playlist.m3u"
        ))
        svc.accept()
        XCTAssertEqual(store.playlistURL, "https://other.server/playlist.m3u")
        XCTAssertNil(svc.pendingDiscovery)
    }

    func testDismissAddsToDismissedSetAndClears() {
        let store = SettingsStore.testing()
        let svc = ZenithDiscoveryService(settingsStore: store)
        svc.simulatePending(DiscoveredServer(
            name: "TestServer",
            playlistURL: "https://other.server/playlist.m3u"
        ))
        svc.dismiss()
        XCTAssertNil(svc.pendingDiscovery)
        let saved = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        XCTAssertTrue(saved.contains("https://other.server/playlist.m3u"))
    }

    func testDismissedURLsPersistedAcrossInstances() {
        let store = SettingsStore.testing()
        let svc1 = ZenithDiscoveryService(settingsStore: store)
        svc1.simulatePending(DiscoveredServer(
            name: "TestServer",
            playlistURL: "https://other.server/playlist.m3u"
        ))
        svc1.dismiss()

        let svc2 = ZenithDiscoveryService(settingsStore: store)
        XCTAssertTrue(svc2.isDismissed("https://other.server/playlist.m3u"))
    }

    func testAcceptIsNoOpWhenNoPending() {
        let store = SettingsStore.testing()
        let svc = ZenithDiscoveryService(settingsStore: store)
        svc.accept()
        XCTAssertFalse(store.isConfigured)
    }

    func testDismissIsNoOpWhenNoPending() {
        let store = SettingsStore.testing()
        let svc = ZenithDiscoveryService(settingsStore: store)
        svc.dismiss()
        let saved = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        XCTAssertTrue(saved.isEmpty)
    }
}
