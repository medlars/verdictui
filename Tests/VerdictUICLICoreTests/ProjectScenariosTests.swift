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

    /// CONTROL: the warning must not be unconditional.
    ///
    /// SUPERSEDED PREMISE, 2026-08-31, kept rather than deleted because its
    /// INTENT is still right and only its subject was wrong. It used to assert
    /// that a project declaring ANY runner is not warned, on the reading that
    /// declaring one means the runner is used. Nothing executes a declared
    /// SwiftUI runner: `declaredRunner` has one production consumer, and the
    /// engine is built with `DemoScenarios.registry` unconditionally. So the old
    /// assertion made a consumer able to SILENCE a true warning by adding a file,
    /// while still receiving verdicts about VerdictUI's fixtures.
    ///
    /// The property worth keeping — that the warning is not always-on — cannot be
    /// asserted through `standard()` in process: under `swift test`,
    /// `CommandLine.arguments[0]` is Xcode's `xctest` agent, so the running
    /// binary is never the project's own. It is asserted against the pure rule
    /// below instead, and against the real binary in the commit's live check.
    func testTheFallbackWarningIsNotUnconditional() {
        XCTAssertTrue(
            ProjectScenarios.runnerBelongsToProject(
                runningBinary: URL(fileURLWithPath: "/p/VerdictUI/.build/debug/verdictui"),
                projectRoot: URL(fileURLWithPath: "/p/VerdictUI")),
            "no input makes the rule report ownership, so the note fires on every "
                + "project forever — which is how a real signal becomes noise nobody reads"
        )
    }
}

// MARK: - A declared runner nobody executes must not silence the borrowed-catalog note

extension ProjectScenariosTests {

    /// THE DEFECT. `usesFallbackCatalog` documents itself as "whether the
    /// registry this environment carries is VerdictUI's own demo catalog rather
    /// than the invoking project's" — a claim about the REGISTRY. It is derived
    /// from the MANIFEST, and those are different facts.
    ///
    /// `CommandEnvironment.standard` builds `VerdictEngine(registry:
    /// DemoScenarios.registry)` unconditionally, and NOTHING in the package
    /// executes a declared SwiftUI runner: `declaredRunner` has exactly one
    /// production consumer (Commands.swift), which uses it only as `!= nil`.
    /// Enumerated over the whole package, the other references are this file's
    /// own tests.
    ///
    /// So a consumer that adds `.verdictui/config.json` — the step
    /// `docs/adoption.md` prescribes — changes exactly one observable thing: it
    /// SILENCES the note telling them the scenarios are not theirs. The verdicts
    /// still describe VerdictUI's demo fixtures. That is worse than not adopting,
    /// because a config file plus a quiet run reads as coverage that does not
    /// exist, and this project has shipped that shape before (`no.md` #34: a
    /// ported API with no caller; a runbook describing a transport that did not
    /// exist).
    ///
    /// The discriminator is whether the declared runner IS the running binary.
    /// VerdictUI's own manifest points at `.build/release/verdictui` and its
    /// scenarios genuinely ARE the compiled-in catalog, so `false` is correct
    /// there. A consumer naming a DIFFERENT executable is naming one we cannot
    /// run, so the catalog they get is borrowed and the note must stand.
    @MainActor
    func testAConsumerRunnerWeCannotExecuteDoesNotSilenceTheNote() throws {
        try withTempProject { root in
        try writeManifest(at: root, runner: "build/some-consumer-runner")
        let env = CommandEnvironment.standard(root: root)

        XCTAssertTrue(
            env.usesFallbackCatalog,
            "a project declaring a runner this binary never executes was reported as "
                + "owning its scenarios. The engine still carries DemoScenarios.registry, "
                + "so the note that would have told the caller their verdicts describe "
                + "VerdictUI's fixtures has been silenced by adding a file."
        )
        }
    }

    /// The rule itself, in both directions.
    ///
    /// Tested as a PURE FUNCTION because the environment it governs cannot be
    /// exercised in process: under `swift test`, `CommandLine.arguments[0]` is
    /// Xcode's `xctest` agent, so the running binary is never the project's own
    /// (measured — `/Applications/Xcode.app/.../Agents/xctest`). A fixture
    /// asserting `standard()` for the owning case could only test a weaker rule
    /// than the one that ships, which is why the OWNING half is verified by
    /// running the real binary instead (recorded in the commit message).
    func testRunnerOwnershipIsDecidedByProjectRootNotPathEquality() {
        let repo = URL(fileURLWithPath: "/Users/x/Projects/VerdictUI")

        // OWNS: a debug binary inside the repo, though the manifest names release.
        XCTAssertTrue(
            ProjectScenarios.runnerBelongsToProject(
                runningBinary: URL(fileURLWithPath: "/Users/x/Projects/VerdictUI/.build/debug/verdictui"),
                projectRoot: repo),
            "path equality would reject this and print a borrowed-catalog note on "
                + "VerdictUI's own debug runs")

        // BORROWS: an installed binary run from a consumer project.
        XCTAssertFalse(
            ProjectScenarios.runnerBelongsToProject(
                runningBinary: URL(fileURLWithPath: "/opt/homebrew/bin/verdictui"),
                projectRoot: URL(fileURLWithPath: "/Users/x/Projects/KastDrive")),
            "a consumer running the installed binary must still be told the catalog "
                + "is not theirs")

        // NEGATIVE CONTROL on the prefix test itself: a SIBLING directory whose
        // path shares a prefix must not count as inside. Without the trailing
        // separator, `/Users/x/Projects/VerdictUI-old` matches `VerdictUI`.
        XCTAssertFalse(
            ProjectScenarios.runnerBelongsToProject(
                runningBinary: URL(fileURLWithPath: "/Users/x/Projects/VerdictUI-old/.build/debug/verdictui"),
                projectRoot: repo),
            "a sibling directory sharing a name prefix was treated as inside the project")
    }

    /// Writes a `.verdictui/config.json` naming `runner`.
    fileprivate func writeManifest(at root: URL, runner: String) throws {
        let dir = root.appendingPathComponent(ProjectScenarios.configDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"runner": "\#(runner)"}"#
            .write(
                to: dir.appendingPathComponent(ProjectScenarios.configFile),
                atomically: true, encoding: .utf8)
    }
}
