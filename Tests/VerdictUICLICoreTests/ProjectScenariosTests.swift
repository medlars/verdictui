import Foundation
import XCTest

@testable import VerdictUICLICore

/// A consumer's scenarios must reach the CLI, or the installed binary can only
/// ever verify VerdictUI itself.
///
/// Measured 2026-08-16 (CTS-99986645): `verdictui list` returned the same six
/// `demo-*` scenarios from LaunchGate, `/tmp` and VerdictUI, because
/// `CommandEnvironment.standard()` hardcodes `DemoScenarios.registry`. The
/// background hook then fired on a real LaunchGate SwiftUI file and reported
/// "checked 6 scenario(s) and found problems" — VerdictUI's OWN fixtures,
/// presented as though they described the edited file. A confident wrong answer
/// is worse than no answer.
///
/// `ScenarioRegistry` holds `@Sendable @MainActor` closures, so it cannot cross
/// a process boundary: a consumer's scenarios are reachable only by RUNNING the
/// consumer's own binary. This pins the discovery half of that — which project
/// a directory belongs to, and whether its declared runner exists.
final class ProjectScenariosTests: XCTestCase {

    private func withTempProject(
        _ body: (URL) throws -> Void
    ) throws {
        // DELIBERATELY built WITHOUT `isDirectory: true`. A URL with no
        // trailing-slash marker is read as a FILE by
        // `URL(fileURLWithPath:relativeTo:)`, which then resolves against its
        // PARENT — measured 2026-08-16: a runner declared `.build/debug/x` in a
        // project at `<tmp>/proj-XXXX` came back as `<tmp>/.build/debug/x`, one
        // directory too high and silently, because the path is well-formed and
        // simply points at nothing.
        //
        // Real callers build this URL however they happen to, so the hostile
        // spelling is the one worth pinning. Adding the marker here would make
        // the test pass against an implementation that still has the bug.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A directory with no manifest declares no runner. The caller must be able
    /// to tell that apart from "a runner that failed", because one is a project
    /// that has not adopted VerdictUI and the other is a broken adoption.
    func testADirectoryWithoutAManifestDeclaresNoRunner() throws {
        try withTempProject { root in
            XCTAssertNil(
                ProjectScenarios.declaredRunner(projectRoot: root),
                "a project with no .verdictui/config.json must declare no runner"
            )
        }
    }

    /// The manifest names the executable that prints the project's registry.
    func testAManifestDeclaresItsRunner() throws {
        try withTempProject { root in
            let dir = root.appendingPathComponent(".verdictui", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"runner": ".build/debug/my-scenarios"}"#
                .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

            let runner = ProjectScenarios.declaredRunner(projectRoot: root)
            XCTAssertEqual(
                runner?.path, root.appendingPathComponent(".build/debug/my-scenarios").path,
                "the runner path must resolve against the PROJECT ROOT, not the cwd — the CLI is "
                    + "invoked from wherever the developer happens to be standing"
            )
        }
    }

    /// A manifest that does not parse is a BROKEN adoption, not an absent one.
    ///
    /// Returning nil here would make a typo indistinguishable from a project
    /// that never adopted VerdictUI, and the caller would silently fall back to
    /// the demo catalog — the exact defect this whole ticket is about.
    func testAMalformedManifestThrowsRatherThanReadingAsAbsent() throws {
        try withTempProject { root in
            let dir = root.appendingPathComponent(".verdictui", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{ not json"
                .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

            XCTAssertThrowsError(
                try ProjectScenarios.declaredRunnerStrict(projectRoot: root),
                "a malformed manifest must be an error, never silently 'no scenarios'"
            )
        }
    }

    /// The manifest is found by walking UP from the working directory, the way
    /// a developer expects when standing in a subdirectory of their project.
    func testTheManifestIsFoundFromASubdirectory() throws {
        try withTempProject { root in
            let dir = root.appendingPathComponent(".verdictui", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try #"{"runner": "bin/scenarios"}"#
                .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

            let deep = root.appendingPathComponent("Sources/Feature/Views", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

            XCTAssertEqual(
                ProjectScenarios.findProjectRoot(startingAt: deep)?.path,
                root.resolvingSymlinksInPath().path,
                "a developer standing in Sources/Feature/Views is still in their project"
            )
        }
    }

    /// CONTROL: the walk must STOP rather than climbing to the filesystem root.
    ///
    /// Without this, a directory with no manifest anywhere above it would find
    /// some unrelated ancestor's manifest — worse than finding none.
    func testTheWalkStopsWhenNoManifestExistsAbove() throws {
        try withTempProject { root in
            let deep = root.appendingPathComponent("a/b/c", isDirectory: true)
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            XCTAssertNil(
                ProjectScenarios.findProjectRoot(startingAt: deep),
                "no manifest above means no project — never a borrowed one"
            )
        }
    }
}

// MARK: - The environment reports WHICH catalog it carries

@MainActor
final class FallbackCatalogSignalTests: XCTestCase {

    /// A project with no manifest gets the demo catalog, and is TOLD so.
    func testAProjectWithoutAManifestIsMarkedAsUsingTheFallback() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vu-nofallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            CommandEnvironment.standard(root: root).usesFallbackCatalog,
            "a project declaring no scenarios receives VerdictUI's own demo catalog and must "
                + "be marked as such — otherwise a caller reports those findings as the "
                + "project's (CTS-99986645)"
        )
    }

    /// CONTROL: a project that DOES declare a runner is not marked.
    ///
    /// Without this, `usesFallbackCatalog` is satisfied by a property that is
    /// always true, and the warning fires on every project forever — which is
    /// how a real signal becomes noise nobody reads.
    func testAProjectDeclaringARunnerIsNotMarkedAsFallback() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vu-adopter-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(".verdictui", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"runner": ".build/debug/scenarios"}"#
            .write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        XCTAssertFalse(
            CommandEnvironment.standard(root: root).usesFallbackCatalog,
            "a project that declares its own scenarios must NOT be warned — a warning that "
                + "fires unconditionally is noise, not a signal"
        )
    }
}
