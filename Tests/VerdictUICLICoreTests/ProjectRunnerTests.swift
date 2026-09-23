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
                    alreadyDelegated: false, catalogRoot: root))
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
                    alreadyDelegated: false, catalogRoot: root))
        }
    }

    func testAProjectWithoutManifestDoesNotDelegate() throws {
        XCTAssertNil(
            try ProjectRunner.destination(
                startingAt: URL(fileURLWithPath: "/"),
                runningBinary: URL(fileURLWithPath: "/usr/bin/true"), alreadyDelegated: false))
    }
}

extension ProjectRunnerTests {
    private func buildProject(
        settings: [String: String], script: String = "exit 0",
        _ body: (URL, URL) throws -> Void
    ) throws {
        try project(runner: "runner") { root in
            var manifest = settings
            manifest["runner"] = "runner"
            try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(".verdictui/config.json"))
            let executable = root.appendingPathComponent("swift-stub")
            try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try body(root, executable)
        }
    }

    func testBuildUsesSafeArgumentsProjectRootAndReleaseConfiguration() throws {
        try buildProject(settings: ["buildProduct": "Consumer;echo-not-a-shell", "configuration": "release"],
                         script: "printf '%s\\n' \"$@\" > arguments.txt\npwd > cwd.txt") { root, executable in
            try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)
            let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
            XCTAssertTrue(arguments.contains("--product=Consumer;echo-not-a-shell\n"))
            XCTAssertTrue(arguments.contains("--configuration=release\n"))
            XCTAssertTrue(arguments.contains("--package-path\n\(root.path)\n"))
            let cwd = try String(contentsOf: root.appendingPathComponent("cwd.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = try FileManager.default.attributesOfItem(atPath: cwd)
            let expected = try FileManager.default.attributesOfItem(atPath: root.path)
            XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, expected[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(actual[.systemNumber] as? NSNumber, expected[.systemNumber] as? NSNumber)
        }
    }

    func testBuildFailureRefusesStaleRunner() throws {
        try buildProject(settings: ["buildProduct": "Consumer"], script: "exit 7") { root, executable in
            XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)) { error in
                XCTAssertTrue(String(describing: error).contains("stale runner was not executed"))
            }
        }
    }

    func testBuildTimeoutIsBounded() throws {
        try buildProject(settings: ["buildProduct": "Consumer"], script: "exec /bin/sleep 3") { root, executable in
            XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, timeout: 0.01, swiftExecutable: executable)) { error in
                XCTAssertTrue(String(describing: error).contains("timed out"))
            }
        }
    }

    func testBuildConfigurationValidationAndDefault() throws {
        for invalid in [["buildProduct": ""], ["buildProduct": "a\0b"], ["buildProduct": "Consumer", "configuration": "--bad"], ["configuration": "release"]] {
            try buildProject(settings: invalid) { root, _ in
                XCTAssertThrowsError(try ProjectScenarios.buildConfiguration(projectRoot: root))
            }
        }
        try buildProject(settings: ["buildProduct": "Consumer"]) { root, _ in
            XCTAssertEqual(try ProjectScenarios.buildConfiguration(projectRoot: root)?.configuration, "debug")
        }
        try buildProject(settings: [:]) { root, _ in
            XCTAssertNil(try ProjectScenarios.buildConfiguration(projectRoot: root))
            try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: root.appendingPathComponent("missing"))
        }
    }

    func testAConsumerCannotDeclareTheStockLauncherAsItsRunner() throws {
        try project(runner: "/usr/bin/true") { root in
            XCTAssertThrowsError(try ProjectRunner.destination(startingAt: root,
                runningBinary: URL(fileURLWithPath: "/usr/bin/true"), alreadyDelegated: false))
        }
    }
}

extension ProjectRunnerTests {
    func testLauncherBuildsBeforeItDelegates() throws {
        try buildProject(settings: ["buildProduct": "Consumer"], script: "echo built > built.txt") { root, executable in
            let config = root.appendingPathComponent(".verdictui/config.json")
            try JSONEncoder().encode(["runner": "/usr/bin/true", "buildProduct": "Consumer"])
                .write(to: config)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("swift"), withDestinationURL: executable)
            let sourceRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let process = Process()
            process.executableURL = sourceRoot.appendingPathComponent(".build/debug/verdictui")
            process.arguments = ["list"]
            process.currentDirectoryURL = root
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: ProjectRunner.delegationMarker)
            environment["PATH"] = root.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("built.txt").path))
            XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
        }
    }
}
