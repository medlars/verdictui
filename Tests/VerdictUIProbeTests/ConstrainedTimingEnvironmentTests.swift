import Foundation
@testable import VerdictUIProbe
import XCTest

final class ConstrainedTimingEnvironmentTests: XCTestCase {
    func testTheSwiftPMCacheDetectorProbesActualWrites() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(
            ConstrainedTimingEnvironment.canWriteExistingDirectory(at: directory.path)
        )

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".verdictui-write-probe-") }
        XCTAssertTrue(
            leftovers.isEmpty,
            "the detector must clean up its disposable write probe"
        )
    }

    /// The negative control for the write probe: a path where a mode-bit check
    /// and a real write DISAGREE.
    ///
    /// `testTheConfiguredSwiftPMCachePathsUseTheWriteProbe` cannot fail for this
    /// reason. It reads the REAL cache paths, which on healthy developer
    /// hardware are writable by both methods, so both sides of its equality read
    /// `false` and it holds under either implementation — the shape `no.md` #17
    /// records, where a predicate's tests only ever exercise the agreeing branch.
    ///
    /// A writable REGULAR FILE separates them without needing a sandbox:
    /// measured 2026-08-18, `isWritableFile` returns `true` for it while writing
    /// a child into it fails, because it is not a directory. Reverting the
    /// consumer to `isWritableFile` therefore turns this red.
    func testTheCacheCheckRejectsAPathOnlyARealWriteCanRuleOut() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cte-not-a-directory-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertTrue(
            FileManager.default.isWritableFile(atPath: file.path),
            "the fixture must be one a mode-bit check calls writable, or it "
                + "cannot separate the two implementations"
        )
        XCTAssertTrue(
            ConstrainedTimingEnvironment.hasUnwritableCache(among: [file.path]),
            "the cache check must decide on the write SwiftPM would attempt, "
                + "not on permission bits"
        )
    }

    func testTheConfiguredSwiftPMCachePathsUseTheWriteProbe() {
        let measuredCacheDenials = ConstrainedTimingEnvironment.constrainedSwiftPMCachePaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { !ConstrainedTimingEnvironment.canWriteExistingDirectory(at: $0) }

        XCTAssertEqual(
            ConstrainedTimingEnvironment.hasUnwritableSwiftPMCache,
            measuredCacheDenials.contains(true),
            "the cache fallback must use the same write probe as the configured SwiftPM paths"
        )
        if measuredCacheDenials.contains(true) {
            XCTAssertTrue(
                ConstrainedTimingEnvironment.isActive,
                "an unwritable configured SwiftPM cache must put absolute timing budgets in the record-only lane"
            )
        }
    }
}
