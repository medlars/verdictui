import Foundation

/// Finds the scenarios belonging to the project the CLI was invoked in.
///
/// ## Why this exists
///
/// `CommandEnvironment.standard()` shipped `DemoScenarios.registry` compiled
/// into the binary, so `verdictui list` returned the same six `demo-*`
/// scenarios from every directory on the machine. Measured 2026-08-16
/// (CTS-99986645): identical output from LaunchGate, `/tmp` and VerdictUI. The
/// background hook then fired on a real LaunchGate SwiftUI file and reported
/// "checked 6 scenario(s) and found problems" — VerdictUI's OWN fixtures,
/// presented as though they described the edited file.
///
/// ## Why delegation rather than loading
///
/// `ScenarioRegistry` holds `@Sendable @MainActor` closures that build an
/// `OracleHost` for a concrete `VerdictScenario` type. A closure over a Swift
/// generic cannot cross a process boundary and cannot be reconstructed from
/// JSON, so a consumer's scenarios are reachable ONLY by running code the
/// consumer compiled. The project therefore declares an executable that links
/// `VerdictUIProbe` and answers the same verbs; the CLI delegates to it.
///
/// This needs no dynamic loading, no plugin ABI, and no dlopen — all of which
/// would couple the installed binary to the consumer's toolchain version.
public enum ProjectScenarios {

    /// Directory a project puts its VerdictUI configuration in.
    public static let configDirectory = ".verdictui"
    /// Manifest naming the executable that answers for this project.
    public static let configFile = "config.json"

    /// A manifest that exists but cannot be understood.
    ///
    /// Deliberately an ERROR rather than a nil: a typo in the manifest and a
    /// project that never adopted VerdictUI must not produce the same answer,
    /// because the caller's fallback for "no project scenarios" is the demo
    /// catalog — which is exactly the wrong-answer path this type exists to
    /// close.
    public struct MalformedManifest: Error, CustomStringConvertible {
        public let path: URL
        public let underlying: String
        public var description: String {
            "\(path.path) exists but could not be read as VerdictUI config: \(underlying)"
        }
    }

    private struct Manifest: Decodable {
        let runner: String
    }

    /// The nearest ancestor of `directory` holding a `.verdictui/config.json`.
    ///
    /// Walks UP, because a developer editing `Sources/Feature/Views/Foo.swift`
    /// is still standing in their project. Stops at the filesystem root rather
    /// than borrowing an unrelated ancestor's manifest — a borrowed manifest
    /// would verify one project's scenarios and label them another's, which is
    /// the same class of wrong answer as the demo-catalog fallback.
    public static func findProjectRoot(startingAt directory: URL) -> URL? {
        var current = directory.resolvingSymlinksInPath()
        while true {
            let candidate = current
                .appendingPathComponent(configDirectory, isDirectory: true)
                .appendingPathComponent(configFile)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().resolvingSymlinksInPath()
            // `/`.deletingLastPathComponent() is `/`, so compare rather than
            // looping forever on a machine with no manifest anywhere.
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    /// Whether `runningBinary` is the declaring project's OWN executable.
    ///
    /// The discriminator behind `CommandEnvironment.usesFallbackCatalog`, kept
    /// as a pure function because the environment it governs cannot be tested
    /// in process: under `swift test`, `CommandLine.arguments[0]` is Xcode's
    /// `xctest` agent (measured 2026-08-31 —
    /// `/Applications/Xcode.app/.../Agents/xctest`), so the running binary is
    /// NEVER the project's binary inside a test. A fixture there could only ever
    /// exercise a weaker rule than the one that ships.
    ///
    /// Compared by PROJECT ROOT, not by path equality. Equality was tried and
    /// measured wrong: VerdictUI's manifest names `.build/release/verdictui`, so
    /// running the DEBUG binary from its own repo printed the borrowed-catalog
    /// note against its own scenarios — a false warning in the one case the flag
    /// exists to suppress.
    public static func runnerBelongsToProject(
        runningBinary: URL,
        projectRoot: URL
    ) -> Bool {
        let binary = runningBinary.resolvingSymlinksInPath().standardizedFileURL
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        return binary.path.hasPrefix(root.path + "/")
    }

    /// The runner this project declares, or `nil` when it declares none.
    ///
    /// Swallows a malformed manifest into `nil`; use ``declaredRunnerStrict``
    /// when the difference matters, which is everywhere a fallback follows.
    public static func declaredRunner(projectRoot: URL) -> URL? {
        try? declaredRunnerStrict(projectRoot: projectRoot)
    }

    /// The runner this project declares. Throws on a manifest that exists but
    /// does not parse; returns `nil` only when there is genuinely no manifest.
    public static func declaredRunnerStrict(projectRoot: URL) throws -> URL? {
        let manifestPath = projectRoot
            .appendingPathComponent(configDirectory, isDirectory: true)
            .appendingPathComponent(configFile)
        guard FileManager.default.fileExists(atPath: manifestPath.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: manifestPath)
        } catch {
            throw MalformedManifest(path: manifestPath, underlying: "\(error)")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw MalformedManifest(path: manifestPath, underlying: "\(error)")
        }

        // Resolve against the PROJECT ROOT, not the process's cwd: the CLI is
        // invoked from wherever the developer is standing, and a runner path
        // resolved against that would be found only by accident.
        // Re-derive the base as an explicit DIRECTORY url rather than trusting
        // the caller's. `URL(fileURLWithPath:relativeTo:)` reads a base with no
        // trailing-slash marker as a FILE and resolves against its PARENT, so a
        // runner declared `.build/debug/x` in a project at `<tmp>/proj-XXXX`
        // comes back as `<tmp>/.build/debug/x` — one directory too high, and
        // silently: the path is well-formed and simply points at nothing.
        // Measured 2026-08-16 against both spellings.
        let base = URL(fileURLWithPath: projectRoot.path, isDirectory: true)
        let runner = URL(fileURLWithPath: manifest.runner, relativeTo: base)
        return runner.absoluteURL.standardizedFileURL
    }
}
