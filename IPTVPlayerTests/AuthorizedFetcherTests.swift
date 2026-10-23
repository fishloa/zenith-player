import CryptoKit
import XCTest
@testable import IPTVPlayer

final class AuthorizedFetcherTests: XCTestCase {
    private var servers: [TestHTTPServer] = []
    override func tearDown() { servers.forEach { $0.stop() }; servers = []; super.tearDown() }

    private func server(_ h: @escaping @Sendable (TestRequest) -> TestResponse) async throws -> (TestHTTPServer, URL) {
        let s = try TestHTTPServer(h)
        servers.append(s)
        return (s, try await s.baseURL())
    }

    private func fetcher(_ creds: [(URL, Credential)] = []) -> AuthorizedFetcher {
        let store = CredentialStore(secrets: InMemorySecretStore())
        for (u, c) in creds { store.set(c, for: Origin(u)!) }
        return AuthorizedFetcher(credentials: store)
    }

    private static func basicOK(_ r: TestRequest) -> TestResponse {
        r.headers["authorization"] == "Basic " + Data("u:p".utf8).base64EncodedString()
            ? TestResponse(status: 200, body: Data("ok".utf8))
            : TestResponse(status: 401, headers: ["WWW-Authenticate": #"Basic realm="test""#])
    }

    func testNoCredentialReportsTheChallenge() async throws {
        let (_, base) = try await server { _ in
            TestResponse(status: 401, headers: ["WWW-Authenticate": #"Bearer realm="zenith", resource_metadata="https://x.example/.well-known/oauth-protected-resource""#])
        }
        do {
            _ = try await fetcher().data(from: base.appendingPathComponent("playlist.m3u"))
            XCTFail("expected 401")
        } catch let e as FetchError {
            XCTAssertEqual(e, .unauthorized(AuthChallenge(scheme: "bearer", realm: "zenith",
                                                          resourceMetadata: URL(string: "https://x.example/.well-known/oauth-protected-resource")),
                                            Origin(base)!, rejected: false))
        }
    }

    func testBasicCredentialAnswersTheChallenge() async throws {
        let (_, base) = try await server(Self.basicOK)
        let (data, _) = try await fetcher([(base, .password(user: "u", password: "p"))]).data(from: base.appendingPathComponent("p"))
        XCTAssertEqual(data, Data("ok".utf8))
    }

    func testWrongPasswordIsRejectedOnce() async throws {
        let (s, base) = try await server(Self.basicOK)
        do {
            _ = try await fetcher([(base, .password(user: "u", password: "wrong"))]).data(from: base.appendingPathComponent("p"))
            XCTFail("expected rejection")
        } catch let e as FetchError {
            XCTAssertEqual(e, .unauthorized(AuthChallenge(scheme: "basic", realm: "test", resourceMetadata: nil), Origin(base)!, rejected: true))
        }
        XCTAssertLessThanOrEqual(s.requests.count, 2)
    }

    func testDigestCredentialAnswersTheChallenge() async throws {
        let (_, base) = try await server { r in
            func md5(_ s: String) -> String { Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
            guard let auth = r.headers["authorization"], let (scheme, p) = AuthChallenge.parameters(auth), scheme == "digest",
                  let nc = p["nc"], let cnonce = p["cnonce"], let uri = p["uri"] else {
                return TestResponse(status: 401, headers: ["WWW-Authenticate": #"Digest realm="t", qop="auth", nonce="n1", algorithm=MD5"#])
            }
            let expected = md5("\(md5("u:t:p")):n1:\(nc):\(cnonce):auth:\(md5("GET:\(uri)"))")
            return p["response"] == expected ? TestResponse(status: 200, body: Data("ok".utf8)) : TestResponse(status: 403)
        }
        let (data, _) = try await fetcher([(base, .password(user: "u", password: "p"))]).data(from: base.appendingPathComponent("d"))
        XCTAssertEqual(data, Data("ok".utf8))
    }

    func testBearerIsSentToItsOrigin() async throws {
        let (s, base) = try await server { r in
            r.headers["authorization"] == "Bearer tok" ? TestResponse(status: 200) : TestResponse(status: 401)
        }
        _ = try await fetcher([(base, .bearer("tok"))]).data(from: base.appendingPathComponent("p"))
        XCTAssertEqual(s.requests.first?.headers["authorization"], "Bearer tok")
    }

    func testCredentialsNotSentToOtherOrigin() async throws {
        let (other, otherBase) = try await server { _ in TestResponse(status: 200, body: Data("logo".utf8)) }
        let (_, base) = try await server { _ in
            TestResponse(status: 302, headers: ["Location": otherBase.appendingPathComponent("logo.png").absoluteString])
        }
        let (data, _) = try await fetcher([(base, .bearer("tok"))]).data(from: base.appendingPathComponent("logo.png"))
        XCTAssertEqual(data, Data("logo".utf8))
        XCTAssertNil(other.requests.first?.headers["authorization"])
    }

    func testForbiddenDoesNotAskForCredentials() async throws {
        let (_, base) = try await server { _ in TestResponse(status: 403) }
        do {
            _ = try await fetcher().data(from: base.appendingPathComponent("p"))
            XCTFail("expected 403")
        } catch let e as FetchError {
            XCTAssertEqual(e, .forbidden)
        }
    }

    func testOtherStatusIsAnHTTPError() async throws {
        let (_, base) = try await server { _ in TestResponse(status: 404) }
        do {
            _ = try await fetcher().data(from: base.appendingPathComponent("p"))
            XCTFail("expected 404")
        } catch let e as FetchError {
            XCTAssertEqual(e, .http(status: 404))
        }
    }

    func testBasicChallengeWithoutCredentialIsNotRejected() async throws {
        let (_, base) = try await server(Self.basicOK)
        do {
            _ = try await fetcher().data(from: base.appendingPathComponent("p"))
            XCTFail("expected 401")
        } catch let e as FetchError {
            XCTAssertEqual(e, .unauthorized(AuthChallenge(scheme: "basic", realm: "test", resourceMetadata: nil), Origin(base)!, rejected: false))
        }
    }

    func testServerTrustGetsDefaultHandling() async {
        let space = URLProtectionSpace(host: "tv.example.org", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                   failureResponse: nil, error: nil, sender: NoSender())
        let store = CredentialStore(secrets: InMemorySecretStore())
        let origin = Origin(URL(string: "https://tv.example.org")!)!
        store.set(.password(user: "u", password: "p"), for: origin)
        let delegate = AuthDelegate(origin: origin, credentials: store)
        let task = URLSession.shared.dataTask(with: URL(string: "https://tv.example.org")!)
        let (disposition, credential) = await delegate.urlSession(URLSession.shared, task: task, didReceive: challenge)
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(credential)
    }
    func testCredentialForRedirectTargetIsUsed() async throws {
        let (target, targetBase) = try await server { r in
            r.headers["authorization"] == "Bearer tokB" ? TestResponse(status: 200, body: Data("b".utf8)) : TestResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        let (_, base) = try await server { _ in TestResponse(status: 302, headers: ["Location": targetBase.appendingPathComponent("x").absoluteString]) }
        let (data, _) = try await fetcher([(targetBase, .bearer("tokB"))]).data(from: base.appendingPathComponent("x"))
        XCTAssertEqual(data, Data("b".utf8))
        XCTAssertEqual(target.requests.last?.headers["authorization"], "Bearer tokB")
    }

    func testStaleBearerIsRejected() async throws {
        let (_, base) = try await server { _ in TestResponse(status: 401, headers: ["WWW-Authenticate": #"Bearer realm="z""#]) }
        do {
            _ = try await fetcher([(base, .bearer("old"))]).data(from: base.appendingPathComponent("p"))
            XCTFail("expected 401")
        } catch let e as FetchError {
            XCTAssertEqual(e, .unauthorized(AuthChallenge(scheme: "bearer", realm: "z", resourceMetadata: nil), Origin(base)!, rejected: true))
        }
    }
}

final class NoSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
