import ApplicationServices
import XCTest

@testable import VerdictUIWitness

final class AXReaderGuardTests: XCTestCase {
    func testNegativeStructuralIndexIsRefusedBeforeChildLookup() {
        let application = AXUIElementCreateApplication(getpid())
        XCTAssertNil(AXReader.element(at: "root/button[-1]", from: application))
    }

    func testStructuralIndexValidationHasPositiveAndNegativeControls() {
        XCTAssertNil(AXReader.structuralPathIndex("-1"))
        XCTAssertNil(AXReader.structuralPathIndex("999999999999999999999999999"))
        XCTAssertNil(AXReader.structuralPathIndex("word"))
        XCTAssertEqual(AXReader.structuralPathIndex("0"), 0)
        XCTAssertEqual(AXReader.structuralPathIndex("12"), 12)
    }

    func testNegativeWindowIndexIsRefusedBeforeReadingAnotherProcess() {
        XCTAssertThrowsError(try AXReader.anchor(pid: getpid(), surface: .window(-1))) { error in
            XCTAssertEqual(error as? AXReader.Failure, .surfaceNotFound("window:-1"))
        }
    }

    func testWindowIndexGuardRejectsOnlyNegativeIndices() {
        XCTAssertThrowsError(try AXReader.requireWindowIndex(-1)) { error in
            XCTAssertEqual(error as? AXReader.Failure, .surfaceNotFound("window:-1"))
        }
        XCTAssertNoThrow(try AXReader.requireWindowIndex(0))
        XCTAssertNoThrow(try AXReader.requireWindowIndex(12))
    }

    func testAccessibilityPreflightFlagsDoNotReplaceActualReads() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/VerdictUIWitness/AXReader.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("guard isTrusted"),
            "the advisory trust flag must not prevent the authoritative read/action")
        XCTAssertTrue(source.contains("AXUIElementCopyAttributeValue(app, kAXWindowsAttribute"))
        XCTAssertTrue(source.contains("throw Failure.noWindow(axError: status.rawValue)"))
    }

    func testNonpositivePIDsNeverReachAccessibility() {
        for pid: pid_t in [-1, 0] {
            XCTAssertThrowsError(try AXReader.readSurface(pid: pid, surface: .menuBar)) { error in
                guard case .hostUnavailable = error as? AXReader.Failure else {
                    return XCTFail("expected invalid target refusal, got \(error)")
                }
            }
            XCTAssertThrowsError(try AXReader.readAllSurfaces(pid: pid))
        }
    }
}
