import XCTest

@testable import VerdictUIKernel

/// `SchemaVersion` is the whole compatibility policy in four symbols, and every
/// consumer (CLI, MCP, agent) inherits whatever it decides. These tests pin the
/// policy itself; `SchemaCompatibilityTests` pins that the decoder obeys it.
final class SchemaVersionTests: XCTestCase {

    func testCurrentIsTheVersionTheSchemaFileDeclares() {
        // Hard-coded rather than read back from SchemaVersion: comparing the
        // constant to itself would pass through any accidental bump. The JSON
        // schema pins the same literal, and contracts/validate-contracts.py
        // fails if the two ever drift.
        XCTAssertEqual(SchemaVersion.current, "1.1")
        XCTAssertEqual(SchemaVersion.currentMajor, 1)
    }

    func testMajorAcceptsMajorAndMajorMinorShapes() {
        XCTAssertEqual(SchemaVersion.major(of: "1"), 1)
        XCTAssertEqual(SchemaVersion.major(of: "1.0"), 1)
        XCTAssertEqual(SchemaVersion.major(of: "2.17"), 2)
        XCTAssertEqual(SchemaVersion.major(of: "10.0"), 10)
        XCTAssertEqual(SchemaVersion.major(of: "0.9"), 0)
    }

    /// The doc comment promises `nil` for anything not `major`/`major.minor`
    /// shaped. Reading `"1.2.3"` as major 1 would accept a payload built to a
    /// versioning scheme this kernel has never seen.
    func testMajorRejectsEveryMalformedShape() {
        for malformed in [
            "", ".", "1.", ".1", "1.2.3", "v1.0", "1.x", "one", "1,0", " 1.0", "1.0 ", "-1.0",
        ] {
            XCTAssertNil(SchemaVersion.major(of: malformed), "'\(malformed)' must not parse")
        }
    }

    func testIsCompatibleMatchesOnMajorAndIgnoresMinor() {
        XCTAssertTrue(SchemaVersion.isCompatible("1.0"))
        XCTAssertTrue(SchemaVersion.isCompatible("1"), "a bare major is the same major")
        XCTAssertTrue(
            SchemaVersion.isCompatible("1.99"),
            "a newer minor only adds optional fields, which this kernel ignores"
        )
    }

    func testIsCompatibleRejectsAForeignMajorInEitherDirection() {
        XCTAssertFalse(SchemaVersion.isCompatible("0.9"), "older major: fields may be missing")
        XCTAssertFalse(SchemaVersion.isCompatible("2.0"), "newer major: meanings may have changed")
        XCTAssertFalse(SchemaVersion.isCompatible("10.0"))
    }

    func testIsCompatibleRejectsAMalformedVersionRatherThanDefaulting() {
        for malformed in ["", "1.2.3", "not-a-version", "1.x"] {
            XCTAssertFalse(
                SchemaVersion.isCompatible(malformed),
                "'\(malformed)' must not be treated as compatible"
            )
        }
    }

    /// `currentMajor` falls back to 0 when `current` cannot be parsed. A bump to
    /// an unparseable string would therefore make every *major-0* payload look
    /// compatible and every real one look foreign — silently. Assert the fallback
    /// is not the value in play.
    func testCurrentIsWellShapedSoTheCurrentMajorFallbackNeverFires() throws {
        let parsed = try XCTUnwrap(
            SchemaVersion.major(of: SchemaVersion.current),
            "SchemaVersion.current must be major.minor shaped or currentMajor silently becomes 0"
        )
        XCTAssertEqual(SchemaVersion.currentMajor, parsed)
        XCTAssertNotEqual(SchemaVersion.currentMajor, 0, "0 is the failure fallback, not a major")
        XCTAssertTrue(SchemaVersion.isCompatible(SchemaVersion.current))
    }
}
