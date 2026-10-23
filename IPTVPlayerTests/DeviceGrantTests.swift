import XCTest
@testable import IPTVPlayer

final class DeviceGrantTests: XCTestCase {
    private var server: TestHTTPServer?
    override func tearDown() { server?.stop(); super.tearDown() }

    private func json(_ s: String, _ status: Int = 200) -> TestResponse {
        TestResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
    }

    func testWellKnownPathFollowsRFC8414() {
        XCTAssertEqual(DeviceGrant.wellKnown(issuer: URL(string: "https://a.example")!).absoluteString,
                       "https://a.example/.well-known/oauth-authorization-server")
        XCTAssertEqual(DeviceGrant.wellKnown(issuer: URL(string: "https://a.example/tenant/")!).absoluteString,
                       "https://a.example/.well-known/oauth-authorization-server/tenant")
    }

    func testFullGrantWithPendingAndSlowDown() async throws {
        let state = PollState()
        let s = try TestHTTPServer { [unowned self] r in
            switch r.path {
            case "/.well-known/oauth-protected-resource":
                return self.json(#"{"resource":"\#(state.base)","authorization_servers":["\#(state.base)"]}"#)
            case "/.well-known/oauth-authorization-server":
                return self.json(#"{"issuer":"\#(state.base)","device_authorization_endpoint":"\#(state.base)/device","token_endpoint":"\#(state.base)/token"}"#)
            case "/device":
                XCTAssertTrue(String(decoding: r.body, as: UTF8.self).contains("client_id=zenith-player"))
                return self.json(#"{"device_code":"dc","user_code":"ABCD-1234","verification_uri":"\#(state.base)/link","expires_in":600,"interval":1}"#)
            case "/token":
                XCTAssertTrue(String(decoding: r.body, as: UTF8.self).contains("device_code=dc"))
                switch state.next() {
                case 0: return self.json(#"{"error":"authorization_pending"}"#, 400)
                case 1: return self.json(#"{"error":"slow_down"}"#, 400)
                default: return self.json(#"{"access_token":"tok","token_type":"Bearer"}"#)
                }
            default: return TestResponse(status: 404)
            }
        }
        server = s
        state.base = try await s.baseURL().absoluteString
        var sleeps: [Duration] = []
        let grant = DeviceGrant(sleep: { sleeps.append($0) })
        let ep = try await grant.endpoints(resourceMetadata: URL(string: state.base + "/.well-known/oauth-protected-resource")!, for: Origin(URL(string: state.base)!)!)
        let auth = try await grant.start(ep.device)
        XCTAssertEqual(auth.userCode, "ABCD-1234")
        let token = try await grant.poll(ep.token, auth)
        XCTAssertEqual(token, "tok")
        XCTAssertEqual(sleeps, [.seconds(1), .seconds(1), .seconds(6)])
    }

    func testDeniedAndExpired() async throws {
        for (error, expected) in [("access_denied", DeviceGrantError.denied), ("expired_token", .expired)] {
            let s = try TestHTTPServer { [unowned self] _ in self.json(#"{"error":"\#(error)"}"#, 400) }
            defer { s.stop() }
            let base = try await s.baseURL()
            let auth = DeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: base, verificationURIComplete: nil, expiresIn: 60, interval: 1)
            do {
                _ = try await DeviceGrant(sleep: { _ in }).poll(base.appendingPathComponent("token"), auth)
                XCTFail("expected \(expected)")
            } catch let e as DeviceGrantError {
                XCTAssertEqual(e, expected)
            }
        }
    }

    func testGivesUpWhenTheCodeExpires() async throws {
        let s = try TestHTTPServer { [unowned self] _ in self.json(#"{"error":"authorization_pending"}"#, 400) }
        server = s
        let base = try await s.baseURL()
        let auth = DeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: base, verificationURIComplete: nil, expiresIn: 3, interval: 1)
        do {
            _ = try await DeviceGrant(sleep: { _ in }).poll(base.appendingPathComponent("token"), auth)
            XCTFail("expected expiry")
        } catch let e as DeviceGrantError {
            XCTAssertEqual(e, .expired)
        }
    }
    func testMetadataForAnotherResourceIsRejected() async throws {
        let state = PollState()
        let s = try TestHTTPServer { [unowned self] r in
            r.path == "/.well-known/oauth-protected-resource"
                ? self.json(#"{"resource":"https://evil.example","authorization_servers":["\#(state.base)"]}"#)
                : self.json(#"{"issuer":"\#(state.base)","device_authorization_endpoint":"\#(state.base)/device","token_endpoint":"\#(state.base)/token"}"#)
        }
        server = s
        state.base = try await s.baseURL().absoluteString
        do {
            _ = try await DeviceGrant(sleep: { _ in }).endpoints(resourceMetadata: URL(string: state.base + "/.well-known/oauth-protected-resource")!, for: Origin(URL(string: state.base)!)!)
            XCTFail("expected rejection")
        } catch let e as DeviceGrantError { XCTAssertEqual(e, .invalidResponse) }
    }

    func testMetadataFromAnotherIssuerIsRejected() async throws {
        let state = PollState()
        let s = try TestHTTPServer { [unowned self] r in
            r.path == "/.well-known/oauth-protected-resource"
                ? self.json(#"{"resource":"\#(state.base)","authorization_servers":["\#(state.base)"]}"#)
                : self.json(#"{"issuer":"https://other.example","device_authorization_endpoint":"\#(state.base)/device","token_endpoint":"\#(state.base)/token"}"#)
        }
        server = s
        state.base = try await s.baseURL().absoluteString
        do {
            _ = try await DeviceGrant(sleep: { _ in }).endpoints(resourceMetadata: URL(string: state.base + "/.well-known/oauth-protected-resource")!, for: Origin(URL(string: state.base)!)!)
            XCTFail("expected rejection")
        } catch let e as DeviceGrantError { XCTAssertEqual(e, .invalidResponse) }
    }
    func testServerErrorWhilePollingKeepsPolling() async throws {
        let state = PollState()
        let s = try TestHTTPServer { [unowned self] _ in
            state.next() == 0 ? TestResponse(status: 503, body: Data("<html>busy</html>".utf8)) : self.json(#"{"access_token":"tok","token_type":"Bearer"}"#)
        }
        server = s
        let base = try await s.baseURL()
        let auth = DeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: base, verificationURIComplete: nil, expiresIn: 60, interval: 1)
        let token = try await DeviceGrant(sleep: { _ in }).poll(base.appendingPathComponent("token"), auth)
        XCTAssertEqual(token, "tok")
    }
}

final class PollState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var base = ""
    func next() -> Int { lock.lock(); defer { count += 1; lock.unlock() }; return count }
}
