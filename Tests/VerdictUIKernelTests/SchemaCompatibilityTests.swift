import XCTest

@testable import VerdictUIKernel

/// The version boundary: which payloads this kernel agrees to read.
///
/// `SchemaVersion` states that a major bump is breaking and that a consumer must
/// refuse a foreign major "rather than guess". These tests are what makes that
/// sentence true — before them, ``SchemaVersion/isCompatible(_:)`` had no call
/// site at all and every version decoded alike.
final class SchemaCompatibilityTests: XCTestCase {

    /// A minimal, otherwise-valid payload carrying the given schema version.
    private func payload(version: String, extraField: String = "") -> Data {
        let json = """
            {"schemaVersion":"\(version)","scenario":"s",
             "timestamp":"2026-08-04T00:00:00Z","status":"PASS",
             "findings":[],"timing":{}\(extraField)}
            """
        return Data(json.utf8)
    }

    private func assertRejected(
        _ version: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(Verdict.self, from: payload(version: version)),
            "schema '\(version)' should not decode",
            file: file,
            line: line
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)", file: file, line: line)
            }
            // The message has to name both versions, or the operator cannot tell
            // which side is stale. Matched in quotes so the empty-version case
            // asserts something real — `"abc".contains("")` is false in Swift.
            XCTAssertTrue(
                context.debugDescription.contains("'\(version)'"),
                context.debugDescription
            )
            XCTAssertTrue(
                context.debugDescription.contains("'\(SchemaVersion.current)'"),
                context.debugDescription
            )
        }
    }

    func testDecodeRejectsAnOlderIncompatibleMajor() {
        assertRejected("0.9")
    }

    func testDecodeRejectsANewerIncompatibleMajor() {
        // The dangerous direction: every field below still parses, so without the
        // guard this returns a confident verdict built from a contract whose
        // meaning may have changed.
        assertRejected("2.0")
    }

    func testDecodeRejectsAVersionThatIsNotANumber() {
        assertRejected("not-a-version")
    }

    func testDecodeRejectsAnEmptyVersion() {
        assertRejected("")
    }

    func testDecodeRejectsAMissingVersionRatherThanAssumingCurrent() throws {
        let json = """
            {"scenario":"s","timestamp":"2026-08-04T00:00:00Z",
             "status":"PASS","findings":[],"timing":{}}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(Verdict.self, from: Data(json.utf8))) {
            error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "schemaVersion")
        }
    }

    func testDecodeAcceptsANewerMinorAndIgnoresWhatItDoesNotKnow() throws {
        // The forward-compatibility promise: a minor bump only adds optional
        // fields, so an older reader keeps working by skipping them.
        let data = payload(version: "1.7", extraField: ",\"fieldFromTheFuture\":{\"a\":[1,2]}")
        let verdict = try JSONDecoder().decode(Verdict.self, from: data)
        XCTAssertEqual(verdict.schemaVersion, "1.7")
        XCTAssertEqual(verdict.scenario, "s")
        XCTAssertEqual(verdict.status, .pass)
    }

    func testEncodeStampsTheCurrentVersionSoRoundTripsStayReadable() throws {
        let encoded = try JSONEncoder().encode(Verdict(scenario: "s", findings: []))
        let reread = try JSONDecoder().decode(Verdict.self, from: encoded)
        XCTAssertEqual(reread.schemaVersion, SchemaVersion.current)
    }

    /// Pins the helper to the enforcement. If someone later widens
    /// `isCompatible` (say, to allow a major-2 payload) without touching the
    /// decoder, or vice versa, this fails instead of letting the two drift.
    func testTheCompatibilityRuleAndTheDecoderAgreeOnEveryVersion() {
        for version in ["1.0", "1.1", "1.99", "0.9", "2.0", "10.0", "not-a-version", ""] {
            let helperSaysYes = SchemaVersion.isCompatible(version)
            let decoderSaysYes: Bool
            do {
                _ = try JSONDecoder().decode(Verdict.self, from: payload(version: version))
                decoderSaysYes = true
            } catch {
                decoderSaysYes = false
            }
            XCTAssertEqual(
                helperSaysYes,
                decoderSaysYes,
                "isCompatible(\(version)) = \(helperSaysYes) but decoding succeeded = "
                    + "\(decoderSaysYes)"
            )
        }
    }
}
