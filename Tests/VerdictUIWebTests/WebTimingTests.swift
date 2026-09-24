import XCTest
@testable import VerdictUIWeb

/// CIS-4ADF5658: fixed capture budgets held on developer hardware and ran out on
/// hosted CI runners (~2x slower), so heavy fixtures refused with "deadline
/// exceeded" instead of the verdict under test. The scale is the one knob.
final class WebTimingTests: XCTestCase {
    func testAbsentOrInvalidScaleKeepsTheProductDefaults() {
        for value in [nil, "", "abc", "0", "-2", "nan", "inf", "0.5"] {
            let env = value.map { [WebTiming.scaleVariable: $0] } ?? [:]
            XCTAssertEqual(WebTiming.scale(from: env), 1, "value \(String(describing: value))")
        }
        XCTAssertEqual(WebTiming(scale: 1).captureDeadline, .seconds(10))
        XCTAssertEqual(WebTiming(scale: 1).requestCap, .seconds(5))
    }

    func testAValidScaleStretchesEveryBudgetAndIsBounded() {
        XCTAssertEqual(WebTiming.scale(from: [WebTiming.scaleVariable: "3"]), 3)
        XCTAssertEqual(WebTiming.scale(from: [WebTiming.scaleVariable: "2.5"]), 2.5)
        XCTAssertEqual(WebTiming.scale(from: [WebTiming.scaleVariable: "500"]), WebTiming.maximumScale)
        let timing = WebTiming(scale: 3)
        XCTAssertEqual(timing.captureDeadline, .seconds(30))
        XCTAssertEqual(timing.requestCap, .seconds(15))
        XCTAssertEqual(timing.captureDeadlineDescription, "30 seconds")
    }
}
