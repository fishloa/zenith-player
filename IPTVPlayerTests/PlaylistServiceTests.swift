import XCTest
import Observation
@testable import IPTVPlayer

@MainActor
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
        let svc = PlaylistService(settingsStore: SettingsStore.testing())
        await svc.loadPlaylist()
        XCTAssertTrue(svc.needsSetup)
        XCTAssertNil(svc.errorMessage)
        XCTAssertTrue(svc.channels.isEmpty)
    }

    /// An unreachable server is an error, not a list of sample channels.
    func testFailedLoadShowsNoChannels() async {
        let store = SettingsStore.testing()
        store.playlistURL = "http://127.0.0.1:9/playlist.m3u"
        let svc = PlaylistService(settingsStore: store)
        await svc.loadPlaylist()
        XCTAssertFalse(svc.needsSetup)
        XCTAssertNotNil(svc.errorMessage)
        XCTAssertTrue(svc.channels.isEmpty)
    }
    private func service(_ handler: @escaping @Sendable (TestRequest) -> TestResponse,
                         credential: Credential? = nil,
                         retryDelay: Duration = .seconds(30)) async throws -> (PlaylistService, TestHTTPServer) {
        let server = try TestHTTPServer(handler)
        let base = try await server.baseURL()
        let secrets = InMemorySecretStore()
        let store = SettingsStore.testing(secrets)
        store.playlistURL = base.appendingPathComponent("playlist.m3u").absoluteString
        if let credential { store.credentials.set(credential, for: Origin(base)!) }
        return (PlaylistService(settingsStore: store, fetcher: AuthorizedFetcher(credentials: store.credentials), retryDelay: retryDelay), server)
    }

    func testUnauthorizedPlaylistAsksToSignIn() async throws {
        let (svc, server) = try await service { _ in TestResponse(status: 401, headers: ["WWW-Authenticate": #"Basic realm="tv""#]) }
        defer { server.stop() }
        await svc.loadPlaylist()
        XCTAssertEqual(svc.signIn?.challenge?.scheme, "basic")
        XCTAssertEqual(svc.signIn?.rejected, false)
        XCTAssertNil(svc.errorMessage)
        XCTAssertTrue(svc.channels.isEmpty)
    }

    func testAuthorizedPlaylistLoads() async throws {
        let m3u = "#EXTM3U\n#EXTINF:-1 tvg-id=\"a\" group-title=\"G\",A\nhttp://127.0.0.1:1/stream/a?t=x\n"
        let (svc, server) = try await service({ r in
            r.headers["authorization"] == "Bearer tok" ? TestResponse(status: 200, body: Data(m3u.utf8)) : TestResponse(status: 401)
        }, credential: .bearer("tok"))
        defer { server.stop() }
        await svc.loadPlaylist()
        XCTAssertNil(svc.signIn)
        XCTAssertEqual(svc.channels.count, 1)
        XCTAssertTrue(server.requests[0].path.contains("format=ts"))
    }

    func testForbiddenShowsErrorWithoutSignIn() async throws {
        let (svc, server) = try await service { _ in TestResponse(status: 403) }
        defer { server.stop() }
        await svc.loadPlaylist()
        XCTAssertNil(svc.signIn)
        XCTAssertEqual(svc.errorMessage, "This server does not allow access.")
    }

    func testServerErrorShowsStatus() async throws {
        let (svc, server) = try await service { _ in TestResponse(status: 502) }
        defer { server.stop() }
        await svc.loadPlaylist()
        XCTAssertEqual(svc.errorMessage, "The server returned an error (HTTP 502).")
        XCTAssertTrue(svc.channels.isEmpty)
    }

    func testServerErrorRetriesAutomatically() async throws {
        let counter = RequestCounter()
        let m3u = "#EXTM3U\n#EXTINF:-1 tvg-id=\"a\" group-title=\"G\",A\nhttp://127.0.0.1:1/stream/a?t=x\n"
        let (svc, server) = try await service({ _ in
            if counter.next() == 1 { return TestResponse(status: 502) }
            return TestResponse(status: 200, body: Data(m3u.utf8))
        }, retryDelay: .milliseconds(200))
        defer { server.stop() }
        await svc.loadPlaylist()
        XCTAssertNotNil(svc.errorMessage)
        let deadline = Date().addingTimeInterval(5)
        while svc.channels.count != 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(svc.channels.count, 1)
        XCTAssertNil(svc.errorMessage)
    }

    func testLoadPublishesChangesOnMainThread() async throws {
        let m3u = "#EXTM3U\n#EXTINF:-1 tvg-id=\"a\" group-title=\"G\",A\nhttp://127.0.0.1:1/stream/a?t=x\n"
        let (svc, server) = try await service { _ in TestResponse(status: 200, body: Data(m3u.utf8)) }
        defer { server.stop() }

        let expectation = expectation(description: "channels changed")
        let flag = MainThreadFlag()
        let fulfilled = MainThreadFlag()
        withObservationTracking {
            _ = svc.channels
        } onChange: {
            flag.value = Thread.isMainThread
            if fulfilled.value != true {
                fulfilled.value = true
                expectation.fulfill()
            }
        }

        await Task.detached {
            await svc.loadPlaylist()
        }.value

        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertTrue(flag.value == true)
    }
}

final class MainThreadFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
