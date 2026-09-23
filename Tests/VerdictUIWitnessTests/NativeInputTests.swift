import ApplicationServices
import XCTest

@testable import VerdictUIWitness

final class NativeInputTests: XCTestCase {
    func testDeniedPermissionPostsNothing() throws {
        var posted = 0
        let input = NativeInput(permission: { false }, isAlive: { _ in true }) { _, _ in
            posted += 1
        }
        XCTAssertThrowsError(try input.type("secret", to: 42)) { error in
            XCTAssertEqual(error as? NativeInput.Failure, .permissionDenied)
            XCTAssertFalse(String(describing: error).contains("secret"))
        }
        XCTAssertEqual(posted, 0)
    }

    func testInvalidOrDeadPIDPostsNothing() throws {
        var posted = 0
        let input = NativeInput(permission: { true }, isAlive: { _ in false }) { _, _ in
            posted += 1
        }
        for pid: pid_t in [0, -1, 1] {
            XCTAssertThrowsError(try input.type("x", to: pid)) { error in
                XCTAssertEqual(error as? NativeInput.Failure, .invalidPID)
            }
        }
        XCTAssertThrowsError(try input.type("x", to: 42)) { error in
            XCTAssertEqual(error as? NativeInput.Failure, .processUnavailable(42))
        }
        XCTAssertEqual(posted, 0)
    }

    func testNonFiniteCoordinatesAreRefused() {
        for number in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try NativeInput.Point(x: number, y: 0))
            XCTAssertThrowsError(try NativeInput.Point(x: 0, y: number))
        }
    }

    func testKeyChordsValidateTheWholeSpecification() throws {
        XCTAssertEqual(try NativeInput.KeyChord("cmd+shift+a").keyCode, 0)
        XCTAssertEqual(
            try NativeInput.KeyChord("command+shift+a").modifierFlags,
            [.maskCommand, .maskShift])
        XCTAssertEqual(try NativeInput.KeyChord("return").keyCode, 36)
        XCTAssertEqual(try NativeInput.KeyChord("control+left").keyCode, 123)
        for invalid in ["", "command", "cmd++a", "+a", "cmd+cmd+a", "cmd+unknown", "a+b"] {
            XCTAssertThrowsError(try NativeInput.KeyChord(invalid), invalid)
        }
    }

    func testTypePreservesUnicodeAndTargetsOnlyTheRequestedPID() throws {
        var pids: [pid_t] = []
        var downText = ""
        var eventTypes: [CGEventType] = []
        let input = NativeInput(permission: { true }, isAlive: { _ in true }) { event, pid in
            pids.append(pid)
            eventTypes.append(event.type)
            if event.type == .keyDown {
                var length = 0
                var units = [UniChar](repeating: 0, count: 20)
                event.keyboardGetUnicodeString(
                    maxStringLength: units.count, actualStringLength: &length,
                    unicodeString: &units)
                downText += String(decoding: units.prefix(length), as: UTF16.self)
            }
        }
        try input.type("A🦉é", to: 42)
        XCTAssertEqual(downText, "A🦉é")
        XCTAssertEqual(pids, [42, 42])
        XCTAssertEqual(eventTypes, [.keyDown, .keyUp])
    }

    func testMouseSequenceCarriesCoordinatesAndNeverUsesAGlobalSink() throws {
        var events: [(CGEventType, CGPoint, pid_t)] = []
        let input = NativeInput(permission: { true }, isAlive: { _ in true }) { event, pid in
            events.append((event.type, event.location, pid))
        }
        let start = try NativeInput.Point(x: 10, y: 20)
        let end = try NativeInput.Point(x: 70, y: 100)
        try input.click(at: start, to: 42)
        XCTAssertEqual(events.map(\.0), [.leftMouseDown, .leftMouseUp])
        XCTAssertTrue(events.allSatisfy { $0.1 == CGPoint(x: 10, y: 20) && $0.2 == 42 })
        events = []
        try input.drag(from: start, to: end, pid: 42)
        XCTAssertEqual(events.first?.0, .leftMouseDown)
        XCTAssertEqual(events.last?.0, .leftMouseUp)
        XCTAssertTrue(events.dropFirst().dropLast().allSatisfy { $0.0 == .leftMouseDragged })
        XCTAssertEqual(events.last?.1, CGPoint(x: 70, y: 100))
        XCTAssertTrue(events.allSatisfy { $0.2 == 42 })
    }

    func testKeyFlagsApplyToBothDownAndUp() throws {
        var events: [CGEvent] = []
        let input = NativeInput(permission: { true }, isAlive: { _ in true }) { event, _ in
            events.append(event)
        }
        try input.key(NativeInput.KeyChord("command+shift+a"), to: 42)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.flags == [.maskCommand, .maskShift] })
        XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 0 })
    }

    func testMouseInputWithoutATargetWindowIsRefusedBeforePosting() throws {
        var posted = 0
        let input = NativeInput(
            permission: { true }, isAlive: { _ in true }, windowAtPoint: { _, _ in nil }
        ) { _, _ in posted += 1 }
        XCTAssertThrowsError(try input.click(at: .init(x: 1, y: 2), to: 42)) { error in
            XCTAssertEqual(error as? NativeInput.Failure, .targetWindowUnavailable)
        }
        XCTAssertEqual(posted, 0)
    }

    func testMouseInputWithoutWindowGeometryIsRefusedBeforePosting() throws {
        var posted = 0
        let input = NativeInput(
            permission: { true }, isAlive: { _ in true }, windowFrame: { _ in nil }
        ) { _, _ in posted += 1 }
        XCTAssertThrowsError(try input.click(at: .init(x: 1, y: 2), to: 42)) { error in
            XCTAssertEqual(error as? NativeInput.Failure, .targetWindowUnavailable)
        }
        XCTAssertEqual(posted, 0)
    }

    func testEmptyTextIsRefusedBeforePosting() {
        var posted = 0
        let input = NativeInput(permission: { true }, isAlive: { _ in true }) { _, _ in posted += 1 }
        XCTAssertThrowsError(try input.type("", to: 42)) { error in
            XCTAssertEqual(error as? NativeInput.Failure, .emptyText)
        }
        XCTAssertEqual(posted, 0)
    }

    func testForeignWindowEventsUseItsIDAndRelativeCoordinates() throws {
        var events: [CGEvent] = []
        let input = NativeInput(
            permission: { true }, isAlive: { _ in true }, windowAtPoint: { _, _ in 4321 },
            windowFrame: { _ in CGRect(x: 100, y: 200, width: 300, height: 400) }
        ) { event, _ in events.append(event) }
        try input.click(at: .init(x: 150, y: 260), to: 42)
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(event.location, CGPoint(x: 50, y: 60))
            XCTAssertEqual(NSEvent(cgEvent: event)?.windowNumber, 4321)
        }
    }

    func testLongUnicodeChunksDoNotSplitASurrogatePair() throws {
        var observed = ""
        let input = NativeInput(permission: { true }, isAlive: { _ in true }) { event, _ in
            if event.type == .keyDown {
                var length = 0
                var units = [UniChar](repeating: 0, count: 20)
                event.keyboardGetUnicodeString(
                    maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
                observed += String(decoding: units.prefix(length), as: UTF16.self)
            }
        }
        let text = String(repeating: "x", count: 19) + "🦉more"
        try input.type(text, to: 42)
        XCTAssertEqual(observed, text)
    }

    func testAnAXSelectedWindowIsNotReplacedByAnOverlappingWindow() {
        let chosen = CGRect(x: 100, y: 100, width: 300, height: 300)
        func window(_ pid: Int32, _ id: UInt32, _ frame: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let front = window(42, 10, CGRect(x: 50, y: 50, width: 500, height: 500))
        let target = window(42, 20, chosen)
        let otherProcess = window(99, 30, chosen)
        XCTAssertEqual(
            NativeInput.matchingWindow(pid: 42, frame: chosen, windows: [front, otherProcess, target]), 20)
        XCTAssertNil(NativeInput.matchingWindow(pid: 42, frame: chosen, windows: [front, otherProcess]))
        XCTAssertNil(NativeInput.matchingWindow(pid: 42, frame: chosen, windows: [target, target]),
            "indistinguishable windows must be refused, never chosen arbitrarily")
    }
}
