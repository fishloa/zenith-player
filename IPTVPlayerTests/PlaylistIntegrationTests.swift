import XCTest
@testable import IPTVPlayer

/// Against a live Zenith server: set ZENITH_TEST_SERVER to its base URL
/// (scripts/test-app.sh passes it through). Skipped otherwise.
enum LiveServer {
    static func playlistURL() throws -> URL {
        let base = ProcessInfo.processInfo.environment["ZENITH_TEST_SERVER"] ?? ""
        try XCTSkipIf(base.isEmpty, "ZENITH_TEST_SERVER not set")
        return try XCTUnwrap(URL(string: base)).appendingPathComponent("playlist.m3u")
    }
}

final class PlaylistIntegrationTests: XCTestCase {

    private var playlistURL: URL!

    override func setUpWithError() throws {
        playlistURL = try LiveServer.playlistURL()
    }

    private func fetchPlaylist() async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: playlistURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func testPlaylistFetchReturnsChannels() async throws {
        let m3u = try await fetchPlaylist()
        let channels = M3UParser.parse(m3u)
        XCTAssertGreaterThan(channels.count, 0, "Expected at least one channel from live playlist")
    }

    func testPlaylistContainsFranceGroup() async throws {
        let m3u = try await fetchPlaylist()
        let channels = M3UParser.parse(m3u)
        let france = channels.filter { $0.group == "France" }
        XCTAssertGreaterThan(france.count, 0, "Expected France group in playlist")
    }

    func testPlaylistContainsItalyGroup() async throws {
        let m3u = try await fetchPlaylist()
        let channels = M3UParser.parse(m3u)
        let italy = channels.filter { $0.group == "Italy" }
        XCTAssertGreaterThan(italy.count, 0, "Expected Italy group in playlist")
    }

    func testAllChannelsHaveValidStreamURLs() async throws {
        let m3u = try await fetchPlaylist()
        let channels = M3UParser.parse(m3u)
        for channel in channels {
            XCTAssertTrue(
                channel.streamURL.absoluteString.hasPrefix("http"),
                "Channel \(channel.name) stream URL not HTTP: \(channel.streamURL)"
            )
        }
    }

    func testPlaylistServiceLoadsLiveChannels() async throws {
        let store = SettingsStore()
        store.playlistURL = playlistURL.absoluteString
        let service = PlaylistService(settingsStore: store)
        await service.loadPlaylist()
        XCTAssertNil(service.errorMessage, "Expected no error loading live playlist, got: \(service.errorMessage ?? "")")
        XCTAssertGreaterThan(service.channels.count, 0, "Expected channels after load")
    }
}
