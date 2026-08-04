import SwiftUI
import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIProbe

final class VerdictUIProbeTests: XCTestCase {
    func testVerdictFramesKeyMergesLaterValuesOverEarlier() {
        var accumulated: [String: Rect] = ["a": Rect(x: 0, y: 0, width: 10, height: 10)]
        VerdictFramesKey.reduce(value: &accumulated) {
            [
                "a": Rect(x: 1, y: 1, width: 20, height: 20),
                "b": Rect(x: 5, y: 5, width: 30, height: 30),
            ]
        }
        XCTAssertEqual(accumulated["a"], Rect(x: 1, y: 1, width: 20, height: 20))
        XCTAssertEqual(accumulated["b"], Rect(x: 5, y: 5, width: 30, height: 30))
    }

    @MainActor
    func testVerdictProbeModifierCompilesIntoViewTree() {
        // Smoke: the modifier applies without crashing and yields a valid View.
        // Real resolved-frame assertions arrive with the Wave 2 oracle harness.
        let view = Text("Save").verdictProbe("save-button")
        XCTAssertNotNil(view)
    }
}
