import XCTest
@testable import ZenithMedia

final class ByteSourceTests: XCTestCase {
    func testFileSourceYieldsWholeFileInChunks() async throws {
        let url = Fixtures.root.appendingPathComponent("audio/mux-aligned.ts")
        let expected = try Data(contentsOf: url)
        var got = Data(), chunks = 0
        for try await c in FileByteSource(url: url, bytesPerSecond: nil, chunk: 65536).bytes() { got += c; chunks += 1 }
        XCTAssertEqual(got, expected)
        XCTAssertEqual(chunks, (expected.count + 65535) / 65536)
    }
}
