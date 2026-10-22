import XCTest
@testable import IPTVPlayer

final class PlaylistServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "playlistURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "playlistURL")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "playlistURL")
        NSUbiquitousKeyValueStore.default.removeObject(forKey: "playlistURL")
        super.tearDown()
    }

    /// Nothing configured: no request, no error, the app shows setup.
    func testUnconfiguredLoadNeedsSetup() async {
        let svc = PlaylistService(settingsStore: SettingsStore())
        await svc.loadPlaylist()
        XCTAssertTrue(svc.needsSetup)
        XCTAssertNil(svc.errorMessage)
        XCTAssertTrue(svc.channels.isEmpty)
    }

    /// An unreachable server is an error, not a list of sample channels.
    func testFailedLoadShowsNoChannels() async {
        let store = SettingsStore()
        store.playlistURL = "http://127.0.0.1:9/playlist.m3u"
        let svc = PlaylistService(settingsStore: store)
        await svc.loadPlaylist()
        XCTAssertFalse(svc.needsSetup)
        XCTAssertNotNil(svc.errorMessage)
        XCTAssertTrue(svc.channels.isEmpty)
    }
}
