import XCTest
import ZenithMediaFFI
@testable import ZenithMedia

final class PauseReasonDecodingTests: XCTestCase {
    func testPauseReasonDecoding() {
        guard let session = ZMSession(url: URL(string: "http://example.com/x.ts")!, nowMicros: 0) else {
            XCTFail("session creation failed")
            return
        }
        func decode(_ code: UInt8) -> PauseReason? {
            var ev = zm_event()
            ev.kind = UInt32(ZM_EV_BUFFER)
            ev.status = 2
            ev.status_value = 42
            ev.track_id = 0
            ev.pause_reason = code
            guard case .buffer(.pause(_, _, let reason)) = session.clientEvent(from: ev) else { return nil }
            return reason
        }
        XCTAssertEqual(decode(3), .discontinuity)
        XCTAssertEqual(decode(0), .unknown)
        XCTAssertEqual(decode(99), .unknown)
    }
}
