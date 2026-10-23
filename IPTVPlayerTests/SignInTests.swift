import XCTest
@testable import IPTVPlayer

final class SignInTests: XCTestCase {
    private let origin = Origin(URL(string: "https://tv.example.org")!)!

    func testPasswordFormForBasicAndDigest() {
        for scheme in ["basic", "digest"] {
            let r = SignInRequest(origin: origin, challenge: AuthChallenge(scheme: scheme, realm: "tv", resourceMetadata: nil), rejected: false)
            XCTAssertEqual(SignInMethod.methods(for: r), [.password])
        }
    }

    func testDeviceCodeAndTokenForBearerWithMetadata() {
        let md = URL(string: "https://tv.example.org/.well-known/oauth-protected-resource")!
        let r = SignInRequest(origin: origin, challenge: AuthChallenge(scheme: "bearer", realm: "zenith", resourceMetadata: md), rejected: false)
        XCTAssertEqual(SignInMethod.methods(for: r), [.deviceCode(md), .token])
    }

    func testTokenWhenNothingElseIsKnown() {
        XCTAssertEqual(SignInMethod.methods(for: SignInRequest(origin: origin, challenge: nil, rejected: false)), [.token])
        let bearer = SignInRequest(origin: origin, challenge: AuthChallenge(scheme: "bearer", realm: nil, resourceMetadata: nil), rejected: true)
        XCTAssertEqual(SignInMethod.methods(for: bearer), [.token])
    }
}
