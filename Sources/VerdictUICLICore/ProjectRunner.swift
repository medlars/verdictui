import Darwin
import Foundation
import os
import VerdictUIKernel
import VerdictUIProbe

/// Runs the existing CLI and MCP handlers with the consumer's compiled scenarios.
public enum VerdictUIRunner {
    @TaskLocal static var environment: CommandEnvironment?

    @MainActor
    public static func main(
        registry: ScenarioRegistry,
        root: URL? = nil,
        arguments: [String]? = nil,
        usesFallbackCatalog: Bool = false,
        allowsExternalWitness: Bool = false
    ) async {
        let directory =
            root ?? ProjectScenarios.findProjectRoot(
                startingAt: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        await withRegistry(
            registry, root: directory, usesFallbackCatalog: usesFallbackCatalog,
            allowsExternalWitness: allowsExternalWitness
        ) {
            await VerdictUITool.main(arguments)
        }
    }

    @MainActor
    static func withRegistry<Result: Sendable>(
        _ registry: ScenarioRegistry,
        root: URL,
        usesFallbackCatalog: Bool = false,
        allowsExternalWitness: Bool = false,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let environment = CommandEnvironment(
            usesFallbackCatalog: usesFallbackCatalog,
            engine: VerdictEngine(
                registry: registry, baselines: .standard(root: root),
                allowsExternalWitness: allowsExternalWitness
            ),
            output: StandardOutput(),
            pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory, isDirectory: true),
            projectRoot: root
        )
        return try await $environment.withValue(environment) { try await operation() }
    }
}

/// Replaces the installed launcher with the project's executable, preserving stdio and signals.
public enum ProjectRunner {
    static let delegationMarker = "VERDICTUI_PROJECT_RUNNER_DELEGATED"

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        /// The signal that interrupted a consumer build, after its session was swept.
        public var interruption: Int32? = nil
    }

    static let buildInterruptions = [SIGINT, SIGTERM, SIGHUP]

    /// Turns interrupting signals into build cancellation, so the owned build
    /// session is swept before the launcher exits. Signals the process already
    /// ignores stay ignored. Death without a handler, including SIGKILL, is the
    /// launch guardian's job.
    private static func withBuildInterruption<Result>(
        _ body: (_ received: () -> Int32?) throws -> Result
    ) rethrows -> Result {
        let received = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        var installed: [(Int32, sigaction, any DispatchSourceSignal)] = []
        for number in buildInterruptions {
            var current = sigaction()
            guard sigaction(number, nil, &current) == 0,
                unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self)
                    != unsafeBitCast(SIG_IGN, to: Int.self)
            else { continue }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { received.withLock { if $0 == nil { $0 = number } } }
            source.resume()
            signal(number, SIG_IGN)
            installed.append((number, current, source))
        }
        defer {
            for (number, previous, source) in installed {
                var restored = previous
                sigaction(number, &restored, nil)
                source.cancel()
            }
        }
        return try body { received.withLock { $0 } }
    }

    public struct Destination: Equatable, Sendable {
        public let executable: URL
        public let projectRoot: URL
    }

    public static func destination(
        startingAt directory: URL,
        runningBinary: URL,
        alreadyDelegated: Bool,
        catalogRoot: URL? = nil
    ) throws -> Destination? {
        guard !alreadyDelegated else {
            throw Failure(
                description:
                    "project runner delegated back to verdictui; use VerdictUIRunner.main(registry:)")
        }
        guard let root = ProjectScenarios.findProjectRoot(startingAt: directory),
            let runner = try ProjectScenarios.declaredRunnerStrict(projectRoot: root)
        else { return nil }
        let executable = runner.resolvingSymlinksInPath().standardizedFileURL
        let current = runningBinary.resolvingSymlinksInPath().standardizedFileURL
        let sourceRoot = catalogRoot ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ownsStockCatalog = root.resolvingSymlinksInPath() == sourceRoot.resolvingSymlinksInPath()
        if executable == current {
            guard ownsStockCatalog else {
                throw Failure(description: "project runner is the stock launcher; compile a consumer using VerdictUIRunner.main(registry:)")
            }
            return nil
        }
        // Debug and release builds of this same launcher use its own fixture catalog.
        // Ownership is still false: location alone never certifies a custom registry.
        let buildRoot = root.appendingPathComponent(".build").path + "/"
        if ownsStockCatalog, current.path.hasPrefix(buildRoot), executable.path.hasPrefix(buildRoot),
            current.lastPathComponent == executable.lastPathComponent
        {
            return nil
        }
        try validateDeclaredRunnerExecutable(at: executable)
        return Destination(executable: executable, projectRoot: root)
    }

    public static func shouldForward(arguments: [String]) -> Bool {
        guard !arguments.contains("--help"), !arguments.contains("-h"),
            !arguments.contains("--version")
        else { return false }
        let verb = arguments.first(where: { !$0.hasPrefix("-") }) ?? "list"
        if verb == "sweep",
            arguments.contains(where: {
                $0 == "--app" || $0 == "--pid" || $0.hasPrefix("--app=") || $0.hasPrefix("--pid=")
            })
        {
            return false
        }
        return [
            "list", "render", "verify", "actions", "act", "focus", "baseline", "sweep", "daemon", "mcp",
        ].contains(verb)
    }

    private static func validateDeclaredRunnerExecutable(at executable: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw Failure(
                description:
                    "project runner is missing or not executable: \(executable.path); build the consumer's runner first"
            )
        }
    }

    private static func swiftBuildArguments(
        build: ProjectScenarios.BuildConfiguration, extra: [String] = []
    ) -> [String] {
        [
            "swift", "build", "--package-path", build.packageRoot.path,
            "--product=\(build.product)", "--configuration=\(build.configuration)",
            "--build-system", "native", "--jobs", "2",
        ] + extra
    }

    private static func builtProductExecutable(
        build: ProjectScenarios.BuildConfiguration,
        projectRoot: URL,
        swiftExecutable: URL,
        environment: [String: String]
    ) throws -> URL {
        let output = Pipe()
        let process = try GuardedProcess.spawn(
            executable: swiftExecutable,
            arguments: swiftBuildArguments(build: build, extra: ["--show-bin-path"]),
            directory: projectRoot, environment: environment,
            standardOutput: output.fileHandleForWriting.fileDescriptor,
            standardError: STDERR_FILENO)
        defer { try? output.fileHandleForWriting.close() }
        while try process.status() == nil {
            _ = process.waitForExitEvent(timeout: 0.025)
        }
        if try process.stop(grace: 0) != 0 {
            throw Failure(description: "could not resolve built runner location")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard
            let directory = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !directory.isEmpty
        else {
            throw Failure(description: "could not resolve built runner location")
        }
        let executable = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(build.product)
        try validateDeclaredRunnerExecutable(at: executable)
        return executable
    }

    @discardableResult
    static func buildIfConfigured(
        projectRoot: URL,
        timeout: TimeInterval? = nil,
        swiftExecutable: URL = URL(fileURLWithPath: "/usr/bin/env"),
        shouldCancel: () -> Bool = { false }
    ) throws -> URL? {
        guard let build = try ProjectScenarios.buildConfiguration(projectRoot: projectRoot) else {
            return nil
        }
        let timeout = timeout ?? build.timeoutSeconds
        let environment = ProcessInfo.processInfo.environment
        let arguments = swiftBuildArguments(build: build)
        let event = try JSONSerialization.data(
            withJSONObject: [
                "event": "project-build", "product": build.product,
                "configuration": build.configuration,
                "buildTimeoutSeconds": timeout,
            ], options: [.sortedKeys])
        FileHandle.standardError.write(event + Data([10]))
        try withBuildInterruption { interruption in
            let process = try GuardedProcess.spawn(
                executable: swiftExecutable, arguments: arguments,
                directory: projectRoot, environment: environment,
                standardOutput: STDERR_FILENO, standardError: STDERR_FILENO)
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                while try process.status() == nil {
                    if let number = interruption() {
                        throw Failure(description: "consumer build interrupted by signal \(number)",
                                      interruption: number)
                    }
                    guard !shouldCancel(), ProcessInfo.processInfo.systemUptime < deadline else {
                        throw Failure(
                            description: shouldCancel()
                                ? "consumer build cancelled"
                                : "consumer build timed out after \(timeout) seconds")
                    }
                    _ = process.waitForExitEvent(timeout: 0.025)
                }
                guard try process.stop(grace: 0) == 0 else {
                    throw Failure(description: "consumer build failed; stale runner was not executed")
                }
            } catch {
                try process.stop(grace: 0.2)
                throw error
            }
        }
        return try builtProductExecutable(
            build: build, projectRoot: projectRoot, swiftExecutable: swiftExecutable,
            environment: environment)
    }

    static func isStockDaemon(
        arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.starts(with: ["daemon", "start"]) && environment["VERDICTUI_STOCK_DAEMON"] == "1"
    }

    public static func forwardIfDeclared() throws {
        guard !isStockDaemon(arguments: Array(CommandLine.arguments.dropFirst())) else { return }
        guard shouldForward(arguments: Array(CommandLine.arguments.dropFirst())) else { return }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        guard ProcessInfo.processInfo.environment[delegationMarker] == nil else {
            throw Failure(
                description:
                    "project runner delegated back to verdictui; use VerdictUIRunner.main(registry:)"
            )
        }
        var builtRunner: URL?
        if let root = ProjectScenarios.findProjectRoot(startingAt: current) {
            do {
                builtRunner = try buildIfConfigured(projectRoot: root)
            } catch let failure as Failure {
                guard let number = failure.interruption else { throw failure }
                FileHandle.standardError.write(Data("verdictui: \(failure)\n".utf8))
                Darwin.exit(128 + number)
            }
        }
        guard
            let target = try destination(
                startingAt: current,
                runningBinary: binary,
                alreadyDelegated: ProcessInfo.processInfo.environment[delegationMarker] != nil
            )
        else { return }
        let build = try ProjectScenarios.buildConfiguration(projectRoot: target.projectRoot)
        let runner =
            builtRunner.flatMap { built in
                build.map { $0.product == built.lastPathComponent ? built : nil } ?? nil
            } ?? target.executable
        // Resolve data/baseline paths consistently even when invoked from Sources/Feature.
        guard chdir(target.projectRoot.path) == 0,
            setenv(delegationMarker, target.projectRoot.path, 1) == 0
        else {
            throw Failure(
                description: "could not prepare project runner: \(String(cString: strerror(errno)))"
            )
        }
        let arguments = [runner.path] + CommandLine.arguments.dropFirst()
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        _ = argv.withUnsafeMutableBufferPointer { execv(runner.path, $0.baseAddress!) }
        throw Failure(
            description: "could not execute project runner: \(String(cString: strerror(errno)))")
    }
}
