import XCTest
@testable import IPTVPlayer

final class AuthTests: XCTestCase {
    func testOriginNormalisesSchemeHostAndDefaultPort() throws {
        let a = try XCTUnwrap(Origin(URL(string: "HTTPS://TV.Example.org/playlist.m3u?t=1")!))
        XCTAssertEqual(a, Origin(URL(string: "https://tv.example.org:443/x")!))
        XCTAssertEqual(a.description, "https://tv.example.org:443")
        XCTAssertNotEqual(a, Origin(URL(string: "http://tv.example.org/")!))
        XCTAssertEqual(Origin(URL(string: "http://h:8080/")!)?.port, 8080)
        XCTAssertNil(Origin(URL(string: "file:///tmp/x")!))
    }

    func testUserinfoIsSplitOutOfTheURL() {
        let r = Credential.split("https://al%40x:p%20w@tv.example.org/playlist.m3u")
        XCTAssertEqual(r.url, "https://tv.example.org/playlist.m3u")
        XCTAssertEqual(r.credential, .password(user: "al@x", password: "p w"))
        let plain = Credential.split("https://tv.example.org/playlist.m3u?t=abc")
        XCTAssertEqual(plain.url, "https://tv.example.org/playlist.m3u?t=abc")
        XCTAssertNil(plain.credential)
    }

    func testBearerChallengeWithResourceMetadata() {
        let c = AuthChallenge.parse(#"Bearer realm="zenith", resource_metadata="https://tv.example.org/.well-known/oauth-protected-resource""#)
        XCTAssertEqual(c, AuthChallenge(scheme: "bearer", realm: "zenith",
                                        resourceMetadata: URL(string: "https://tv.example.org/.well-known/oauth-protected-resource")))
    }

    func testFirstOfSeveralChallengesWins() {
        let c = AuthChallenge.parse(#"Basic realm="a \"b\"", Bearer realm="c""#)
        XCTAssertEqual(c?.scheme, "basic")
        XCTAssertEqual(c?.realm, #"a "b""#)
    }

    func testBareSchemeAndUnquotedParameters() {
        XCTAssertEqual(AuthChallenge.parse("Bearer"), AuthChallenge(scheme: "bearer", realm: nil, resourceMetadata: nil))
        XCTAssertEqual(AuthChallenge.parameters("Digest realm=x, nonce=\"n\", qop=auth")?.params,
                       ["realm": "x", "nonce": "n", "qop": "auth"])
        XCTAssertNil(AuthChallenge.parse("  "))
    }
}
