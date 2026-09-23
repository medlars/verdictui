import XCTest

@testable import VerdictUIWitness

final class AXActionTests: XCTestCase {
    func testNativeVerbsAreParsedWithoutInventingMissingArguments() throws {
        XCTAssertEqual(AXReader.Action(verb: "click", value: nil), .click)
        XCTAssertEqual(AXReader.Action(verb: "hover", value: nil), .hover)
        XCTAssertEqual(
            AXReader.Action(verb: "key", value: "cmd+a"),
            .key(try NativeInput.KeyChord("cmd+a")))
        XCTAssertEqual(
            AXReader.Action(verb: "drag", value: "-10.5,40"),
            .drag(to: try NativeInput.Point(x: -10.5, y: 40)))
        for value in [nil, "", "10", "10,20,30", "nan,1", "1,inf"] {
            XCTAssertNil(AXReader.Action(verb: "drag", value: value))
        }
        XCTAssertNil(AXReader.Action(verb: "key", value: nil))
        XCTAssertNil(AXReader.Action(verb: "key", value: "cmd+unknown"))
    }

    func testNativeActionDescriptionsNeverContainTypedText() {
        XCTAssertEqual(AXReader.Action.type("secret").description, "type")
        XCTAssertEqual(AXReader.Action.setValue("secret").description, "set-value")
    }

    func testInvalidPIDIsRejectedBeforeAccessibilityLookup() {
        XCTAssertThrowsError(try AXReader.act(pid: 0, atPath: "root", action: .click)) { error in
            XCTAssertEqual(error as? NativeInput.Failure, .invalidPID)
        }
    }
}
