import Foundation
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

final class ProjectRunnerTests: XCTestCase {
    private func project(runner: String, body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".verdictui"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(["runner": runner]).write(
            to: root.appendingPathComponent(".verdictui/config.json"))
        try body(root)
    }

    func testMissingRunnerIsNotDemoFallback() throws {
        try project(runner: "missing") { root in
            XCTAssertThrowsError(
                try ProjectRunner.destination(
                    startingAt: root, runningBinary: URL(fileURLWithPath: "/usr/bin/true"),
                    alreadyDelegated: false))
        }
    }

    func testDelegationCycleIsRefusedEvenWhenRunnerIsCurrentBinary() throws {
        try project(runner: "/usr/bin/true") { root in
            XCTAssertThrowsError(
                try ProjectRunner.destination(
                    startingAt: root, runningBinary: URL(fileURLWithPath: "/usr/bin/true"),
                    alreadyDelegated: true))
        }
    }

    func testExecutableAndRootAreResolvedFromNestedDirectory() throws {
        try project(runner: "/usr/bin/true") { root in
            let nested = root.appendingPathComponent("Sources/Feature")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let result = try XCTUnwrap(
                ProjectRunner.destination(
                    startingAt: nested, runningBinary: URL(fileURLWithPath: "/usr/bin/false"),
                    alreadyDelegated: false))
            XCTAssertEqual(result.executable.path, "/usr/bin/true")
            XCTAssertEqual(result.projectRoot, root.resolvingSymlinksInPath())
        }
    }

    func testCurrentBinaryDoesNotExecItself() throws {
        try project(runner: "/usr/bin/true") { root in
            XCTAssertNil(
                try ProjectRunner.destination(
                    startingAt: root, runningBinary: URL(fileURLWithPath: "/usr/bin/true"),
                    alreadyDelegated: false))
        }
    }

    func testInvalidManifestAndEmptyRunnerFailClosed() throws {
        for runner in ["", "  ", "x\0y"] {
            try project(runner: runner) { root in
                XCTAssertThrowsError(try ProjectScenarios.declaredRunnerStrict(projectRoot: root))
                XCTAssertThrowsError(
                    try ProjectRunner.destination(
                        startingAt: root, runningBinary: URL(fileURLWithPath: "/usr/bin/true"),
                        alreadyDelegated: false))
            }
        }
        try project(runner: "/usr/bin/true") { root in
            try Data("not json".utf8).write(to: root.appendingPathComponent(".verdictui/config.json"))
            XCTAssertThrowsError(
                try ProjectRunner.destination(
                    startingAt: root, runningBinary: URL(fileURLWithPath: "/usr/bin/true"),
                    alreadyDelegated: false))
        }
    }

    func testDirectoryAndNonexecutableAreRefused() throws {
        for runner in [".", "file"] {
            try project(runner: runner) { root in
                try Data().write(to: root.appendingPathComponent("file"))
                XCTAssertThrowsError(
                    try ProjectRunner.destination(
                        startingAt: root, runningBinary: URL(fileURLWithPath: "/usr/bin/true"),
                        alreadyDelegated: false))
            }
        }
    }

    @MainActor
    func testCustomRegistryReachesAllStandardEnvironmentsAndDoesNotLeak() async {
        let root = FileManager.default.temporaryDirectory
        await VerdictUIRunner.withRegistry(ScenarioRegistry([]), root: root) {
            let env = CommandEnvironment.standard()
            XCTAssertFalse(env.usesFallbackCatalog)
            XCTAssertEqual(env.engine.scenarioNames, [])
            XCTAssertEqual(
                env.pixelArtifactRoot,
                root.appendingPathComponent(PixelArtifact.directory, isDirectory: true))
            let response = await VerdictDaemon.handle(
                .init(method: "list", id: "custom"), engine: env.engine)
            if case .scenarios(let names) = response.result {
                XCTAssertEqual(names, [])
            } else {
                XCTFail("custom registry was not dispatched")
            }
        }
        XCTAssertTrue(CommandEnvironment.standard().usesFallbackCatalog)
        XCTAssertFalse(CommandEnvironment.standard().engine.scenarioNames.isEmpty)
    }
}

extension ProjectRunnerTests {
    func testOnlyScenarioCommandsDelegate() {
        for args in [
            [], ["list"], ["verify", "settings"], ["mcp"], ["daemon", "start"], ["sweep", "settings"],
        ] {
            XCTAssertTrue(ProjectRunner.shouldForward(arguments: args), "\(args)")
        }
        for args in [
            ["web", "list"], ["inspect", "--pid", "1"], ["judge", "tree.json"], ["capture"], ["appkit"],
            ["--help"], ["--version"], ["sweep", "--app", "X.app"], ["sweep", "--pid=1"],
        ] {
            XCTAssertFalse(ProjectRunner.shouldForward(arguments: args), "\(args)")
        }
    }

    @MainActor
    func testCustomDaemonPathsAreStableAndIsolated() async {
        let one = URL(fileURLWithPath: "/tmp/project-one")
        let two = URL(fileURLWithPath: "/tmp/project-two")
        let first = await VerdictUIRunner.withRegistry(ScenarioRegistry([]), root: one) {
            CommandEnvironment.standard().daemonSocketPath
        }
        let again = await VerdictUIRunner.withRegistry(ScenarioRegistry([]), root: one) {
            CommandEnvironment.standard().daemonSocketPath
        }
        let second = await VerdictUIRunner.withRegistry(ScenarioRegistry([]), root: two) {
            CommandEnvironment.standard().daemonSocketPath
        }
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, VerdictDaemon.defaultSocketPath)
        XCTAssertEqual(CommandEnvironment.standard().daemonSocketPath, VerdictDaemon.defaultSocketPath)
    }
}

extension ProjectRunnerTests {
    func testADelegatedLauncherCannotEscapeManifestToReturnDemos() {
        XCTAssertThrowsError(
            try ProjectRunner.destination(
                startingAt: URL(fileURLWithPath: "/"),
                runningBinary: URL(fileURLWithPath: "/usr/bin/true"), alreadyDelegated: true))
    }

    func testDebugAndReleaseOfSameLauncherDoNotDelegate() throws {
        try project(runner: ".build/release/verdictui") { root in
            XCTAssertNil(
                try ProjectRunner.destination(
                    startingAt: root,
                    runningBinary: root.appendingPathComponent(".build/debug/verdictui"),
                    alreadyDelegated: false))
        }
    }

    func testAProjectWithoutManifestDoesNotDelegate() throws {
        XCTAssertNil(
            try ProjectRunner.destination(
                startingAt: URL(fileURLWithPath: "/"),
                runningBinary: URL(fileURLWithPath: "/usr/bin/true"), alreadyDelegated: false))
    }
}
