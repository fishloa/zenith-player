import XCTest
@testable import IPTVPlayer

final class LaunchArgumentsTests: XCTestCase {
    func testValueAfterFlag() {
        XCTAssertEqual(
            LaunchArguments.value(after: "-zenithOpenGroup", in: ["app", "-zenithOpenGroup", "Open Movies"]),
            "Open Movies"
        )
    }

    func testNilWhenFlagIsLast() {
        XCTAssertNil(LaunchArguments.value(after: "-zenithOpenGroup", in: ["app", "-zenithOpenGroup"]))
    }

    func testNilWhenAbsent() {
        XCTAssertNil(LaunchArguments.value(after: "-zenithOpenGroup", in: ["app"]))
    }
}
