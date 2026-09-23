import Darwin
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// Runs the existing CLI and MCP handlers with the consumer's compiled scenarios.
public enum VerdictUIRunner {
    @TaskLocal static var environment: CommandEnvironment?

    @MainActor
    public static func main(
        registry: ScenarioRegistry,
        root: URL? = nil,
        arguments: [String]? = nil
    ) async {
        let directory =
            root ?? ProjectScenarios.findProjectRoot(
                startingAt: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        await withRegistry(registry, root: directory) {
            await VerdictUITool.main(arguments)
        }
    }

    @MainActor
    static func withRegistry<Result>(
        _ registry: ScenarioRegistry,
        root: URL,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        let environment = CommandEnvironment(
            engine: VerdictEngine(registry: registry, baselines: .standard(root: root)),
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
    }

    public struct Destination: Equatable, Sendable {
        public let executable: URL
        public let projectRoot: URL
    }

    public static func destination(
        startingAt directory: URL,
        runningBinary: URL,
        alreadyDelegated: Bool
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
        if executable == current { return nil }
        // Debug and release builds of this same launcher use its own fixture catalog.
        // Ownership is still false: location alone never certifies a custom registry.
        let buildRoot = root.appendingPathComponent(".build").path + "/"
        if current.path.hasPrefix(buildRoot), executable.path.hasPrefix(buildRoot),
            current.lastPathComponent == executable.lastPathComponent
        {
            return nil
        }
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

    public static func forwardIfDeclared() throws {
        guard shouldForward(arguments: Array(CommandLine.arguments.dropFirst())) else { return }
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        guard
            let target = try destination(
                startingAt: current,
                runningBinary: binary,
                alreadyDelegated: ProcessInfo.processInfo.environment[delegationMarker] != nil
            )
        else { return }
        // Resolve data/baseline paths consistently even when invoked from Sources/Feature.
        guard chdir(target.projectRoot.path) == 0,
            setenv(delegationMarker, target.projectRoot.path, 1) == 0
        else {
            throw Failure(
                description: "could not prepare project runner: \(String(cString: strerror(errno)))")
        }
        let arguments = [target.executable.path] + CommandLine.arguments.dropFirst()
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        _ = argv.withUnsafeMutableBufferPointer { execv(target.executable.path, $0.baseAddress!) }
        throw Failure(
            description: "could not execute project runner: \(String(cString: strerror(errno)))")
    }
}
