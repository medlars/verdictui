import Foundation
import SwiftUI
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
        let marker = ScenarioRegistry([ScenarioEntry { TaskLocalLeakMarkerScenario() }])
        await VerdictUIRunner.withRegistry(marker, root: root) {
            let env = CommandEnvironment.standard()
            XCTAssertFalse(env.usesFallbackCatalog)
            XCTAssertEqual(env.engine.scenarioNames, [TaskLocalLeakMarkerScenario.scenarioName])
            XCTAssertEqual(
                env.pixelArtifactRoot,
                root.appendingPathComponent(PixelArtifact.directory, isDirectory: true))
            let response = await VerdictDaemon.handle(
                .init(method: "list", id: "custom"), engine: env.engine)
            if case .scenarios(let names) = response.result {
                XCTAssertEqual(names, [TaskLocalLeakMarkerScenario.scenarioName])
            } else {
                XCTFail("custom registry was not dispatched")
            }
        }
        let after = CommandEnvironment.standard()
        XCTAssertFalse(after.usesFallbackCatalog)
        XCTAssertTrue(
            after.engine.scenarioNames.isEmpty,
            "withRegistry's TaskLocal must not leak past the operation block")
    }
}

private struct TaskLocalLeakMarkerScenario: VerdictScenario, Sendable {
    static let scenarioName = "tasklocal-leak-marker"
    let name = scenarioName

    func body(state: ScenarioState) -> some View {
        Text("marker").verdictProbe("marker", role: .text, text: "marker")
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
    private func consumerSwiftStubScript(product: String, body: String) -> String {
        """
        #!/bin/sh
        ROOT="$(pwd)"
        PRODUCT='\(product)'
        for arg; do
          if [ "$arg" = --show-bin-path ]; then
            touch "$ROOT/invoked-show-bin-path"
            mkdir -p "$ROOT/stub-bin"
            printf '#!/bin/sh\\nexit 0\\n' > "$ROOT/stub-bin/$PRODUCT"
            chmod +x "$ROOT/stub-bin/$PRODUCT"
            echo "$ROOT/stub-bin"
            exit 0
          fi
        done
        \(body)
        """
    }

    private func buildProject(
        settings: [String: Any], script: String = "exit 0",
        _ body: (URL, URL) throws -> Void
    ) throws {
        try project(runner: "runner") { root in
            var manifest = settings
            manifest["runner"] = "runner"
            try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent(".verdictui/config.json"))
            let product = settings["buildProduct"] as? String ?? "Consumer"
            let executable = root.appendingPathComponent("swift-stub")
            try Data(consumerSwiftStubScript(product: product, body: script).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try body(root, executable)
        }
    }

    func testBuildTreeResolutionSkippedForExternalRunner() throws {
        try buildProject(settings: ["buildProduct": "Consumer"], script: "touch invoked-build\n") { root, executable in
            try JSONSerialization.data(withJSONObject: [
                "runner": "/usr/bin/true", "buildProduct": "Consumer",
            ]).write(to: root.appendingPathComponent(".verdictui/config.json"))
            try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)
            XCTAssertNil(
                try ProjectRunner.resolveBuiltRunnerExecutableAfterBuild(
                    projectRoot: root, swiftExecutable: executable))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("invoked-build").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("invoked-show-bin-path").path))
        }
    }

    func testBuiltRunnerPathUsesShowBinPathNotSymlink() throws {
        try project(runner: ".build/debug/Consumer") { root in
            try JSONSerialization.data(withJSONObject: ["runner": ".build/debug/Consumer", "buildProduct": "Consumer"])
                .write(to: root.appendingPathComponent(".verdictui/config.json"))
            let nativeBin = root.appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true)
            try FileManager.default.createDirectory(at: nativeBin, withIntermediateDirectories: true)
            let nativeRunner = nativeBin.appendingPathComponent("Consumer")
            try Data("#!/bin/sh\necho native\n".utf8).write(to: nativeRunner)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nativeRunner.path)

            let staleBin = root.appendingPathComponent("stale/debug", isDirectory: true)
            try FileManager.default.createDirectory(at: staleBin, withIntermediateDirectories: true)
            let staleRunner = staleBin.appendingPathComponent("Consumer")
            try Data("#!/bin/sh\necho stale\n".utf8).write(to: staleRunner)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staleRunner.path)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent(".build/debug"), withDestinationURL: staleBin)

            let executable = root.appendingPathComponent("swift-stub")
            let rootPath = root.path
            try Data(
                ("""
                #!/bin/sh
                ROOT='\(rootPath)'
                for arg; do
                  if [ "$arg" = --show-bin-path ]; then
                    echo "$ROOT/.build/arm64-apple-macosx/debug"
                    exit 0
                  fi
                done
                printf '%s\\n' "$@" > arguments.txt
                exit 0
                """).utf8
            ).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)
            let resolved = try XCTUnwrap(
                try ProjectRunner.resolveBuiltRunnerExecutableAfterBuild(
                    projectRoot: root, swiftExecutable: executable))
            XCTAssertEqual(resolved.standardizedFileURL, nativeRunner.standardizedFileURL)
            XCTAssertNotEqual(resolved.standardizedFileURL, staleRunner.standardizedFileURL)
        }
    }

    func testBuildUsesSafeArgumentsProjectRootAndReleaseConfiguration() throws {
        try buildProject(settings: ["buildProduct": "Consumer;echo-not-a-shell", "configuration": "release"],
                         script: "printf '%s\\n' \"$@\" > arguments.txt\npwd > cwd.txt") { root, executable in
            try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)
            let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
            XCTAssertTrue(arguments.contains("--product=Consumer;echo-not-a-shell\n"))
            XCTAssertTrue(arguments.contains("--configuration=release\n"))
            XCTAssertTrue(arguments.contains("--build-system\nnative\n"))
            XCTAssertTrue(arguments.contains("--package-path\n\(root.resolvingSymlinksInPath().path)\n"))
            let cwd = try String(contentsOf: root.appendingPathComponent("cwd.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actual = try FileManager.default.attributesOfItem(atPath: cwd)
            let expected = try FileManager.default.attributesOfItem(atPath: root.path)
            XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, expected[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(actual[.systemNumber] as? NSNumber, expected[.systemNumber] as? NSNumber)
        }
    }

    func testNestedBuildPackageUsesResolvedPathAndKeepsRunnerRootRelative() throws {
        try buildProject(settings: ["buildProduct": "Consumer", "buildPackagePath": "linked"],
                         script: "printf '%s\\n' \"$@\" > arguments.txt") { root, executable in
            let package = root.appendingPathComponent("app", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: package)
            try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)
            let arguments = try String(contentsOf: root.appendingPathComponent("arguments.txt"), encoding: .utf8)
            XCTAssertTrue(arguments.contains("--package-path\n\(package.resolvingSymlinksInPath().path)\n"))
            XCTAssertEqual(try ProjectScenarios.declaredRunnerStrict(projectRoot: root)?.path,
                           root.appendingPathComponent("runner").path)
        }
    }

    func testInvalidBuildPackagePathsRejectBeforeProcessLaunch() throws {
        let invalid: [Any] = ["", " ", "a\0b", "/", "..", "../sibling", "missing", "file", "escape", true, false, 3, NSNull()]
        for path in invalid {
            try buildProject(settings: ["buildProduct": "Consumer", "buildPackagePath": path],
                             script: "echo launched > launched.txt") { root, executable in
                try Data().write(to: root.appendingPathComponent("file"))
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"),
                                                          withDestinationURL: root.deletingLastPathComponent())
                XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)) { error in
                    XCTAssertTrue(error is ProjectScenarios.MalformedManifest)
                }
                XCTAssertThrowsError(try ProjectScenarios.declaredRunnerStrict(projectRoot: root))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched.txt").path))
            }
        }
        try buildProject(settings: ["buildPackagePath": "."], script: "echo launched > launched.txt") { root, executable in
            XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable))
            XCTAssertThrowsError(try ProjectScenarios.declaredRunnerStrict(projectRoot: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched.txt").path))
        }
    }

    func testRealNestedSwiftPackageBuildProducesItsOwnExecutable() throws {
        try buildProject(settings: ["buildProduct": "NestedConsumer", "buildPackagePath": "app", "buildTimeoutSeconds": 90]) { root, _ in
            let package = root.appendingPathComponent("app", isDirectory: true)
            let source = package.appendingPathComponent("Sources/NestedConsumer", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(name: "NestedConsumer", targets: [.executableTarget(name: "NestedConsumer")])
                """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try "print(\"nested-consumer-built\")".write(to: source.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            try ProjectRunner.buildIfConfigured(projectRoot: root)
            let binary = package.appendingPathComponent(".build/debug/NestedConsumer")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
            let process = Process()
            process.executableURL = binary
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "nested-consumer-built\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/debug/NestedConsumer").path))
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

    // "Running" is proven by the product's own loop, not by a marker the child
    // writes: `buildIfConfigured` can only report "timed out" while
    // `process.status()` is nil, i.e. while the spawned command is alive. A
    // first-line marker instead measured how soon the scheduler ran the child,
    // which failed under contention although the timeout behaved (CIS-96F9AEE5).
    // The monotonic lower bound shows the DECLARED budget governed; the long
    // sleep keeps a starved poll loop from seeing the command finish first.
    func testDeclaredBuildTimeoutReachesRunningCommand() throws {
        try buildProject(settings: ["buildProduct": "Consumer", "buildTimeoutSeconds": 1.5],
                         script: "exec /bin/sleep 30") { root, executable in
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)) { error in
                XCTAssertTrue(String(describing: error).contains("timed out after 1.5 seconds"), "\(error)")
            }
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 1.5)
        }
    }

    func testExplicitTimeoutOverridesProjectBuildBudget() throws {
        try buildProject(settings: ["buildProduct": "Consumer", "buildTimeoutSeconds": 0.01],
                         script: "/bin/sleep 0.05\necho built > built.txt") { root, executable in
            let diagnostics = Pipe()
            let original = dup(STDERR_FILENO)
            guard original >= 0 else { throw POSIXError(.EBADF) }
            defer { close(original) }
            try {
                guard dup2(diagnostics.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == STDERR_FILENO else {
                    throw POSIXError(.EBADF)
                }
                defer { _ = dup2(original, STDERR_FILENO) }
                try ProjectRunner.buildIfConfigured(projectRoot: root, timeout: 1, swiftExecutable: executable)
            }()
            try diagnostics.fileHandleForWriting.close()
            let event = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: diagnostics.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
            XCTAssertEqual(event["buildTimeoutSeconds"] as? Double, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("built.txt").path))
        }
    }

    func testCancellationRemainsEffectiveWithLongProjectBuildBudget() throws {
        try buildProject(settings: ["buildProduct": "Consumer", "buildTimeoutSeconds": 900],
                         script: "exec /bin/sleep 3") { root, executable in
            XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root,
                swiftExecutable: executable, shouldCancel: { true })) { error in
                XCTAssertTrue(String(describing: error).contains("consumer build cancelled"))
            }
        }
    }

    func testInvalidBuildBudgetsRejectBeforeProcessLaunch() throws {
        let invalid: [Any] = [0, -1, 1800.01, true, false, "900", "NaN", NSNull()]
        for timeout in invalid {
            try buildProject(settings: ["buildProduct": "Consumer", "buildTimeoutSeconds": timeout],
                             script: "echo launched > launched.txt") { root, executable in
                XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable)) { error in
                    XCTAssertTrue(error is ProjectScenarios.MalformedManifest)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched.txt").path))
            }
        }
        try buildProject(settings: ["buildTimeoutSeconds": 900], script: "echo launched > launched.txt") { root, executable in
            XCTAssertThrowsError(try ProjectRunner.buildIfConfigured(projectRoot: root, swiftExecutable: executable))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched.txt").path))
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
            try JSONSerialization.data(withJSONObject: ["runner": "/usr/bin/true", "buildProduct": "Consumer", "buildTimeoutSeconds": 900])
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
            let diagnostics = Pipe()
            process.standardOutput = output
            process.standardError = diagnostics
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("built.txt").path))
            XCTAssertEqual(output.fileHandleForReading.readDataToEndOfFile(), Data())
            let event = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: diagnostics.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
            XCTAssertEqual(event["event"] as? String, "project-build")
            XCTAssertEqual(event["buildTimeoutSeconds"] as? Double, 900)
        }
    }
}

extension ProjectRunnerTests {
    func testConfiguredBuildOwnerSIGKILLContainsBuildCommand() throws {
        let fixture = try ConsumerCrashFixture()
        try fixture.write("swift", ConsumerCrashFixture.script, executable: true)
        try fixture.write(".verdictui/config.json", #"{"runner":"/usr/bin/true","buildProduct":"PrivateBuild"}"#)
        try fixture.launch(["list"])
        try fixture.assertCrashContained()
    }
}
