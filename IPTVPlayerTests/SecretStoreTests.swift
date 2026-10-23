import XCTest
@testable import IPTVPlayer

final class SecretStoreTests: XCTestCase {
    private let store = KeychainSecretStore(service: "zenith-player-tests")

    override func tearDown() {
        store.set(nil, for: "k")
        super.tearDown()
    }

    func testKeychainRoundTripAndDelete() {
        store.set(Data("one".utf8), for: "k")
        store.set(Data("two".utf8), for: "k")
        XCTAssertEqual(store.data(for: "k"), Data("two".utf8))
        store.set(nil, for: "k")
        XCTAssertNil(store.data(for: "k"))
    }

    func testCredentialsAreScopedByOrigin() throws {
        let creds = CredentialStore(secrets: InMemorySecretStore())
        let a = try XCTUnwrap(Origin(URL(string: "https://a.example.org")!))
        let b = try XCTUnwrap(Origin(URL(string: "https://b.example.org")!))
        creds.set(.bearer("t"), for: a)
        XCTAssertEqual(creds.credential(for: a), .bearer("t"))
        XCTAssertNil(creds.credential(for: b))
        creds.set(nil, for: a)
        XCTAssertNil(creds.credential(for: a))
    }
}
