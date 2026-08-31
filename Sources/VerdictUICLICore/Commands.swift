// Wave 6: the command surface.
//
// These types parse argv and delegate to `VerdictEngine`. They deliberately
// hold no judgment logic — a command that decided anything itself would be a
// second implementation of `verify`, reachable only through a subprocess.
import ArgumentParser
import Foundation
import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import VerdictUIWitness

/// The scenarios and baseline location a command runs against.
///
/// Injectable so tests drive the real commands against a temporary directory
/// and a fixture registry. A global would make every test that touches
/// baselines share one on-disk directory, and the first failure would cascade.
public struct CommandEnvironment: Sendable {
    public let engine: VerdictEngine
    public let output: OutputSink

    /// Where rendered pixel images are written.
    ///
    /// Injected rather than derived inside the command so a test can point it
    /// at a temporary directory — a command that hardcodes its output path can
    /// only be tested by letting it write into the repository.
    public let pixelArtifactRoot: URL

    /// - Parameter usesFallbackCatalog: defaults to `false` so a caller that
    ///   builds its own registry (every test, the daemon, an embedder) is not
    ///   forced to reason about a flag that does not apply to it. Only
    ///   ``standard(root:)`` derives it, because only it can silently substitute
    ///   the demo catalog for a project's own.
    public init(
        usesFallbackCatalog: Bool = false,
        engine: VerdictEngine,
        output: OutputSink,
        pixelArtifactRoot: URL
    ) {
        self.usesFallbackCatalog = usesFallbackCatalog
        self.engine = engine
        self.output = output
        self.pixelArtifactRoot = pixelArtifactRoot
    }

    /// The default environment: the demo catalog, baselines under the current
    /// directory, writing to the real streams.
    ///
    /// Wave 6 ships the demo catalog as the registry because a consumer's own
    /// scenarios arrive through the Wave 6 Task 3 integration path (building
    /// the consumer's package and loading it), and shipping a CLI that can only
    /// say "no scenarios" would make the whole surface untestable end to end.
    /// Whether the registry this environment carries is VerdictUI's own demo
    /// catalog rather than the invoking project's.
    ///
    /// The catalog is COMPILED IN, so `list` returns the same six `demo-*`
    /// scenarios from any directory on the machine (measured 2026-08-16 in
    /// LaunchGate, `/tmp` and VerdictUI — CTS-99986645). A caller that reports
    /// those as the edited project's findings states something false, so it
    /// needs to be able to ask.
    ///
    /// Derived from the project manifest rather than from the scenario NAMES:
    /// a consumer is free to name a scenario `demo-anything`, and string-matching
    /// the prefix would then mislabel their real catalog as borrowed.
    public let usesFallbackCatalog: Bool

    @MainActor
    public static func standard(root: URL = URL(fileURLWithPath: ".")) -> CommandEnvironment {
        // A project owns its scenarios only if the runner it declares IS THE
        // BINARY NOW RUNNING. Declaring one is not enough, and the difference is
        // the whole point of this flag.
        //
        // `ScenarioRegistry` holds `@Sendable @MainActor` closures, so a
        // consumer's scenarios cannot cross a process boundary — they are
        // reachable only by running the consumer's own executable. Nothing in
        // this package does that for the SwiftUI path: `declaredRunner` has
        // exactly ONE production consumer, this line, and the engine below is
        // built with `DemoScenarios.registry` unconditionally.
        //
        // So treating "a manifest exists" as "the catalog is theirs" let a
        // consumer SILENCE the borrowed-catalog note by adding a file, while
        // still receiving verdicts about VerdictUI's own fixtures. That is worse
        // than not adopting: a config file plus a quiet run reads as coverage
        // that does not exist.
        //
        // VerdictUI's own manifest points at the verdictui binary and its
        // scenarios genuinely ARE the compiled-in catalog, so comparing against
        // the running executable keeps that case correct rather than papering
        // the note over every run of the tool against itself.
        // Compared by PROJECT, not by exact path. Path equality was measured and
        // rejected: VerdictUI's own manifest names `.build/release/verdictui`,
        // so running the DEBUG binary from this repo printed the borrowed-catalog
        // note against its own scenarios — a false warning in the one case the
        // flag exists to keep quiet.
        //
        // The honest question is whether the compiled-in catalog belongs to the
        // project that declared the manifest, answered by asking whether the
        // running binary lives inside that project root.
        let runningBinary = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().standardizedFileURL
        let declaringRoot = ProjectScenarios.findProjectRoot(startingAt: root)
            .flatMap { rt in
                ProjectScenarios.declaredRunner(projectRoot: rt) == nil
                    ? nil : rt.resolvingSymlinksInPath().standardizedFileURL
            }
        let declaresOwnScenarios = declaringRoot.map { rt in
            ProjectScenarios.runnerBelongsToProject(runningBinary: runningBinary, projectRoot: rt)
        } ?? false

        return CommandEnvironment(
            usesFallbackCatalog: !declaresOwnScenarios,
            engine: VerdictEngine(
                registry: DemoScenarios.registry,
                baselines: BaselineStore.standard(root: root)
            ),
            output: StandardOutput(),
            pixelArtifactRoot: root.appendingPathComponent(
                PixelArtifact.directory, isDirectory: true)
        )
    }
}

/// Options every verdict-producing command shares.
public struct FormattingOptions: ParsableArguments, Sendable {
    public init() {}

    @Flag(name: .long, help: "Indent the JSON and sort its keys for human reading.")
    public var pretty = false

    @Flag(name: .long, help: "Print a short human summary instead of JSON.")
    public var summary = false
}

/// Runs a command body and maps its outcome onto the tool's exit codes.
///
/// Centralized because the mapping is the contract: an engine error must never
/// become exit 1, which a caller reads as "your UI is wrong". Every command
/// routes through here so no single command can get that backwards.
public enum CommandRunner {
    @MainActor
    public static func run(
        output: OutputSink,
        body: () async throws -> ExitCode
    ) async -> ExitCode {
        do {
            return try await body()
        } catch let error as VerdictEngine.EngineError {
            output.writeError("verdictui: \(error.description)\n")
            return .couldNotVerify
        } catch let error as BaselineStore.StoreError {
            output.writeError("verdictui: \(error.description)\n")
            return .couldNotVerify
        } catch {
            output.writeError("verdictui: \(error)\n")
            return .couldNotVerify
        }
    }
}

// MARK: - list

/// Names every scenario the tool can run.
public struct ListCommand: Sendable {
    /// Told to a caller whose project has no scenarios of its own.
    ///
    /// A stored constant rather than an inline interpolation: the concatenated
    /// form timed out Swift's type checker ("unable to type-check this
    /// expression in reasonable time"), which is a build failure rather than a
    /// style note.
    public static let fallbackCatalogNote = """
        note: these are VerdictUI's own demo scenarios, not this project's — the catalog is \
        compiled into the binary. This binary is not this project's own runner, so any \
        verdict about them describes VerdictUI's fixtures rather than your code. \
        See docs/adoption.md.
        """

    public init() {}

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let names = environment.engine.scenarioNames
            // STDERR, never stdout: `list` emits a bare JSON array that callers
            // parse. A note prepended to stdout would break every one of them,
            // which is a worse defect than the one being reported.
            if environment.usesFallbackCatalog {
                environment.output.writeError(Self.fallbackCatalogNote)
            }
            environment.output.writeOut(try VerdictOutput.json(names, pretty: pretty))
            return .pass
        }
    }
}

// MARK: - render

/// Prints a scenario's semantic tree.
public struct RenderCommand: Sendable {
    public let scenario: String

    /// Also capture the scenario's pixels, writing the image to disk and
    /// reporting its PATH.
    ///
    /// The image is never inlined into stdout. A base64 PNG would dwarf the
    /// tree it accompanies and cost more than the rest of the payload on the
    /// token-metered MCP surface — and an agent that wants to LOOK at it can
    /// open a path, while one that does not pays nothing.
    public let pixels: Bool

    public init(scenario: String, pixels: Bool = false) {
        self.scenario = scenario
        self.pixels = pixels
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            guard pixels else {
                let tree = try await environment.engine.render(scenario: scenario)
                environment.output.writeOut(try VerdictOutput.json(tree, pretty: pretty))
                return .pass
            }

            let rendered = try await environment.engine.renderPixels(
                scenario: scenario, cache: PixelCache.standard())
            let path = try PixelArtifact.write(
                rendered.capture, under: environment.pixelArtifactRoot)
            environment.output.writeOut(
                try VerdictOutput.json(
                    PixelRenderReport(
                        scenario: scenario,
                        tree: rendered.tree,
                        image: path,
                        pixelsWide: rendered.capture.pixelsWide,
                        pixelsHigh: rendered.capture.pixelsHigh,
                        backend: rendered.capture.backend.rawValue,
                        contentHash: rendered.capture.contentHash,
                        cacheHit: rendered.wasHit
                    ),
                    pretty: pretty))
            return .pass
        }
    }
}

/// Print which probes in a scenario accept an act, and which verbs.
///
/// The discovery half of acting. Without it a caller reads `role` off a
/// rendered tree, guesses, and is refused — and on the shipped catalog it
/// guesses wrong far more often than right, because a role is a claim about
/// what a node IS while actionability is a claim about what the harness can
/// DRIVE.
///
/// Prints a bare `{probe: [verbs]}` object, so a probe ABSENT from the map is
/// not actionable. An `actionable: false` entry per probe was the alternative
/// and is worse for the same reason the compact tree omits empty lists: the
/// common case is "not actionable", and paying to say so on every node is the
/// distribution error `no.md` #41 records.
public struct ActionsCommand: Sendable {
    public let scenario: String

    public init(scenario: String) {
        self.scenario = scenario
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let actionable = try await environment.engine.actionableProbes(scenario: scenario)
            environment.output.writeOut(try VerdictOutput.json(actionable, pretty: pretty))
            return .pass
        }
    }
}

/// What `render --pixels` prints: the tree, plus where the image was written.
///
/// A struct rather than a dictionary because this crosses the wire and is read
/// by a client written against the shape, not against our encoder — the lesson
/// `no.md` #35 cost a whole wave to learn.
public struct PixelRenderReport: Codable, Equatable, Sendable {
    public let scenario: String
    public let tree: SemanticNode
    /// Filesystem path of the PNG. A path, never the bytes — see
    /// ``RenderCommand/pixels``.
    public let image: String
    public let pixelsWide: Int
    public let pixelsHigh: Int
    public let backend: String
    public let contentHash: String
    /// Whether the capture came from the render cache, so a caller can report a
    /// hit rate rather than infer one from timing.
    public let cacheHit: Bool
}

/// The MCP form of a pixel render: the tree compacted, the image still a path.
///
/// A separate type rather than a flag on ``PixelRenderReport`` because the two
/// wires carry genuinely different tree encodings — the socket daemon ships the
/// full `SemanticNode`, MCP ships the compact form — and a single type with an
/// either/or field would let a client decode the wrong one silently.
public struct CompactPixelRender: Codable, Equatable, Sendable {
    public let scenario: String
    public let tree: CompactTree
    /// Path, never bytes. See ``RenderCommand/pixels``.
    public let image: String
    public let pixelsWide: Int
    public let pixelsHigh: Int
    public let backend: String
    public let contentHash: String
    public let cacheHit: Bool

    public init(_ report: PixelRenderReport) {
        scenario = report.scenario
        tree = CompactTree(report.tree)
        image = report.image
        pixelsWide = report.pixelsWide
        pixelsHigh = report.pixelsHigh
        backend = report.backend
        contentHash = report.contentHash
        cacheHit = report.cacheHit
    }
}

/// Writes a capture to a stable, collision-free path under an artifact root.
public enum PixelArtifact {
    /// Default root for rendered images, alongside the diff artifacts.
    public static let directory = "logs/pixel-renders"

    /// Write `capture` and return its path.
    ///
    /// The filename carries the content hash, so re-rendering an unchanged
    /// screen overwrites the same file instead of accumulating one image per
    /// invocation — and two DIFFERENT renders of one scenario never collide.
    ///
    /// - Throws: ``PixelCompareError/artifactWriteFailed(path:reason:)``.
    public static func write(_ capture: PixelCapture, under root: URL) throws -> String {
        // Author-supplied scenario names become path components, so anything
        // that could escape the directory is replaced rather than trusted.
        let slug = String(
            capture.scenarioName.map { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
                    ? character : "-"
            })
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("\(slug)-\(capture.contentHash).png")
            try capture.png.write(to: url)
            return url.path
        } catch {
            throw PixelCompareError.artifactWriteFailed(
                path: root.path, reason: error.localizedDescription)
        }
    }
}

// MARK: - verify

/// Renders a scenario, judges it, and exits on the verdict.
public struct VerifyCommand: Sendable {
    public let scenario: String
    public let useBaseline: Bool
    public let includeTree: Bool
    /// Also reconcile against the external accessibility witness (Wave 8).
    ///
    /// Off by default because it costs a real windowed subprocess and an
    /// Accessibility grant. When ON and the witness cannot run, the verdict
    /// carries a `cross-validation-skipped` warning rather than a quieter
    /// PASS — the caller asked for two channels and must be told it got one.
    public let crossValidate: Bool

    public init(
        scenario: String,
        useBaseline: Bool = false,
        includeTree: Bool = false,
        crossValidate: Bool = false
    ) {
        self.scenario = scenario
        self.useBaseline = useBaseline
        self.includeTree = includeTree
        self.crossValidate = crossValidate
    }

    @MainActor
    public func run(
        _ environment: CommandEnvironment,
        pretty: Bool,
        summary: Bool
    ) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let verdict = try await environment.engine.verify(
                scenario: scenario,
                againstBaseline: useBaseline,
                includeTree: includeTree,
                crossValidate: crossValidate
            )
            environment.output.writeOut(
                summary
                    ? VerdictOutput.humanReadable(verdict)
                    : try VerdictOutput.json(verdict, pretty: pretty)
            )
            // The one place a non-zero exit means the UI rather than the tool.
            return verdict.status == .pass ? .pass : .verdictFailed
        }
    }
}

// MARK: - baseline

/// Shows or accepts baseline drift.
public struct BaselineCommand: Sendable {
    /// What the invocation asked for.
    public enum Mode: Equatable, Sendable {
        /// Report drift without writing anything.
        case diff
        /// Record the current render. `accepted` is `--accept`.
        case update(accepted: Bool)
    }

    public let scenario: String
    public let mode: Mode

    public init(scenario: String, mode: Mode) {
        self.scenario = scenario
        self.mode = mode
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            switch mode {
            case .diff:
                let comparison = try await environment.engine.baselineDiff(scenario: scenario)
                environment.output.writeOut(
                    try VerdictOutput.json(comparison.findings, pretty: pretty)
                )
                return comparison.matches ? .pass : .verdictFailed

            case .update(let accepted):
                // The diff is printed BEFORE the write, always — SD4 requires
                // the destructive command to show what it is about to replace,
                // and a user who sees the delta only afterwards has already
                // accepted it. An absent baseline has no delta to show, which
                // is itself the answer.
                if environment.engine.baselines.exists(scenario: scenario) {
                    let comparison = try await environment.engine.baselineDiff(scenario: scenario)
                    environment.output.writeError(
                        "verdictui: \(comparison.findings.count) change(s) about to be accepted "
                            + "as the new baseline for '\(scenario)'\n"
                    )
                    for finding in comparison.findings {
                        environment.output.writeError("  \(finding.message)\n")
                    }
                }

                let outcome = try await environment.engine.updateBaseline(
                    scenario: scenario,
                    accepted: accepted
                )
                environment.output.writeOut(
                    try VerdictOutput.json(
                        ["scenario": scenario, "outcome": outcome == .created ? "created" : "replaced"],
                        pretty: pretty
                    )
                )
                return .pass
            }
        }
    }
}

// MARK: - sweep

/// Renders a scenario across a variant matrix.
public struct SweepCommand: Sendable {
    public let scenario: String
    public let locales: [String]
    public let colorSchemes: [String]
    public let dynamicTypeSizes: [String]

    public init(
        scenario: String,
        locales: [String] = [],
        colorSchemes: [String] = [],
        dynamicTypeSizes: [String] = []
    ) {
        self.scenario = scenario
        self.locales = locales
        self.colorSchemes = colorSchemes
        self.dynamicTypeSizes = dynamicTypeSizes
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let variants = try VariantParsing.matrix(
                locales: locales,
                colorSchemes: colorSchemes,
                dynamicTypeSizes: dynamicTypeSizes
            )
            let report = try await environment.engine.sweep(
                scenario: scenario,
                variants: variants
            )
            let wire = SweepReportWire(report)
            environment.output.writeOut(try VerdictOutput.json(wire, pretty: pretty))

            // A cell that could not render is NOT a failing verdict: it is an
            // unmeasured cell, and reporting it as a UI defect would send a
            // user looking for a bug that is in the harness.
            if wire.cells.contains(where: { !$0.wasMeasured }) { return .couldNotVerify }
            return wire.isClean ? .pass : .verdictFailed
        }
    }
}

/// Turns command-line variant strings into a matrix.
public enum VariantParsing {
    /// An axis value the vocabulary does not contain.
    public struct UnknownValue: Error, CustomStringConvertible {
        public let axis: String
        public let value: String
        public let accepted: [String]

        public var description: String {
            "unknown \(axis) '\(value)' — accepted: \(accepted.joined(separator: ", "))"
        }
    }

    /// Colour schemes by name.
    ///
    /// An explicit table rather than a `RawRepresentable` init, because
    /// `ColorScheme` has no string raw value and inventing one here would put
    /// the CLI's spelling of "dark" in a different place from the sweep's.
    public static func colorScheme(_ name: String) throws -> ColorScheme {
        switch name.lowercased() {
        case "light": return .light
        case "dark": return .dark
        default:
            throw UnknownValue(axis: "color scheme", value: name, accepted: ["light", "dark"])
        }
    }

    /// Dynamic type sizes by name, covering the whole public vocabulary.
    public static func dynamicTypeSize(_ name: String) throws -> DynamicTypeSize {
        let table: [String: DynamicTypeSize] = [
            "xsmall": .xSmall, "small": .small, "medium": .medium, "large": .large,
            "xlarge": .xLarge, "xxlarge": .xxLarge, "xxxlarge": .xxxLarge,
            "accessibility1": .accessibility1, "accessibility2": .accessibility2,
            "accessibility3": .accessibility3, "accessibility4": .accessibility4,
            "accessibility5": .accessibility5,
        ]
        guard let size = table[name.lowercased()] else {
            throw UnknownValue(
                axis: "dynamic type size",
                value: name,
                accepted: table.keys.sorted()
            )
        }
        return size
    }

    /// Build the cartesian matrix these axes describe.
    public static func matrix(
        locales: [String],
        colorSchemes: [String],
        dynamicTypeSizes: [String]
    ) throws -> [Variant] {
        Sweep<CleanSettingsScenario>.matrix(
            locales: locales,
            colorSchemes: try colorSchemes.map(colorScheme),
            dynamicTypeSizes: try dynamicTypeSizes.map(dynamicTypeSize)
        )
    }
}

// MARK: - judge

/// Judges a semantic tree the CALLER produced — the language-agnostic verb.
///
/// Every other command renders SwiftUI first, which limits the engine to Swift
/// UI. `VerdictUIKernel` never had that limit: it imports only `Foundation`,
/// `Rect` is hand-rolled so it compiles anywhere (`no.md` #5), and
/// `SemanticNode` is `Codable`. So the barrier to judging a React, Flutter or
/// Compose screen was never the rule engine — it was the absence of a way to
/// hand it a tree.
///
/// What this verb does NOT do, stated plainly because the distinction is the
/// whole contract: it does not RENDER non-Swift UI. Producing the tree is the
/// caller's job (a DOM walk, a Flutter semantics dump, an AX scrape). VerdictUI
/// judges what it is given. A tool that claimed to render everything and
/// silently rendered nothing is the failure this project exists to prevent.
public struct JudgeCommand: Sendable {
    /// Path to a JSON `SemanticNode`, or `-` for stdin.
    public let treePath: String
    /// Viewport the rules judge against. A tree carries frames but not the
    /// screen they were laid out in, and `OffscreenRule` needs the screen.
    public let viewportWidth: Double
    public let viewportHeight: Double
    /// Name the verdict is filed under, so a caller judging many trees can tell
    /// them apart in a report.
    public let scenarioName: String

    public init(
        treePath: String,
        viewportWidth: Double = 0,
        viewportHeight: Double = 0,
        scenarioName: String = "judged-tree"
    ) {
        self.treePath = treePath
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.scenarioName = scenarioName
    }

    /// Read the tree bytes, from a file or stdin.
    static func read(_ path: String) throws -> Data {
        if path == "-" {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Judge `tree`, deriving the viewport from the root frame when the caller
    /// did not supply one.
    ///
    /// Separated from `run` so the decision is testable without a process: a
    /// command that only works through argv can only be tested through argv.
    public static func judge(
        tree: SemanticNode,
        viewportWidth: Double,
        viewportHeight: Double,
        scenarioName: String
    ) -> Verdict {
        // A zero viewport is not a viewport. Falling back to the root's own
        // frame means OffscreenRule compares against the surface the caller
        // actually laid out in, rather than an empty rect in which every node
        // is offscreen and every verdict is noise.
        let width = viewportWidth > 0 ? viewportWidth : tree.frame.width
        let height = viewportHeight > 0 ? viewportHeight : tree.frame.height
        let context = LintContext.macOS(
            viewport: Rect(x: 0, y: 0, width: width, height: height),
            scenario: scenarioName
        )
        return RuleEngine.run(rules: RuleEngine.standardRules, on: tree, context: context)
    }

    public func run(
        _ environment: CommandEnvironment,
        pretty: Bool,
        summary: Bool
    ) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let data = try JudgeCommand.read(treePath)
            // A decode failure is a TOOL error (exit 2), never a failing
            // verdict (exit 1) -- "your UI is broken" and "I could not read
            // what you sent me" are different answers, and CommandRunner keeps
            // them apart by letting this throw.
            let tree = try JSONDecoder().decode(SemanticNode.self, from: data)
            let verdict = JudgeCommand.judge(
                tree: tree,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                scenarioName: scenarioName
            )
            environment.output.writeOut(
                summary
                    ? VerdictOutput.humanReadable(verdict)
                    : try VerdictOutput.json(verdict, pretty: pretty)
            )
            return verdict.status == .pass ? .pass : .verdictFailed
        }
    }
}

// MARK: - inspect

/// Read — and optionally press — the UI of a RUNNING application by pid.
///
/// The reachable surface for ``AXReader``, which had none. `readTree(pid:)` and
/// `press(pid:named:)` were correct, tested library API that no CLI verb, MCP
/// tool or production caller could reach, so the capability existed only for
/// someone already writing Swift against the package — precisely the audience
/// that does not need a tool. That is a PORT, not an integration.
///
/// Distinct from `render` on purpose. `render` asks a SCENARIO — an in-process
/// instrumented view VerdictUI owns — what it drew. This asks a process the
/// tool did not write and cannot instrument, which is the only question
/// available for a shipped `.app`, and the one that found two real defects in
/// LaunchGate that a 331-test green suite had shipped.
///
/// No adoption step: it takes a pid, so it answers questions about any GUI
/// product today, before that product declares a single scenario.
public struct InspectCommand: Sendable {
    public let pid: pid_t
    /// When set, PRESS the element with this name instead of printing the tree.
    public let press: String?
    /// When set, PRESS the element at this structural path — the identity the
    /// tree itself prints, so read-then-press round-trips (CIS-3DDA018A).
    public let pressPath: String?

    public init(pid: pid_t, press: String? = nil, pressPath: String? = nil) {
        self.pid = pid
        self.press = press
        self.pressPath = pressPath
    }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            // Trust is checked by the reader and surfaces as a typed failure.
            // Pre-checking here would put the rule in two places where they can
            // disagree — and the reader's answer is authoritative, since
            // `AXIsProcessTrusted()` can be true while a read still fails.
            // PATH FIRST: it is the identity the tree prints, so it is what a
            // caller who just read the tree actually holds. A name is a
            // convenience for a human typing one, and two controls can share it.
            if let path = pressPath {
                try AXReader.press(pid: pid, atPath: path)
                environment.output.writeOut(
                    try VerdictOutput.json(["pressed": path], pretty: pretty))
                return .pass
            }
            if let name = press {
                try AXReader.press(pid: pid, named: name)
                environment.output.writeOut(
                    try VerdictOutput.json(["pressed": name], pretty: pretty))
                return .pass
            }
            let tree = try AXReader.readTree(pid: pid)
            environment.output.writeOut(try VerdictOutput.json(tree, pretty: pretty))
            return .pass
        }
    }
}
