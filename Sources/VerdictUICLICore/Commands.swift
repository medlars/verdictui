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

/// The scenarios and baseline location a command runs against.
///
/// Injectable so tests drive the real commands against a temporary directory
/// and a fixture registry. A global would make every test that touches
/// baselines share one on-disk directory, and the first failure would cascade.
public struct CommandEnvironment: Sendable {
    public let engine: VerdictEngine
    public let output: OutputSink

    public init(engine: VerdictEngine, output: OutputSink) {
        self.engine = engine
        self.output = output
    }

    /// The default environment: the demo catalog, baselines under the current
    /// directory, writing to the real streams.
    ///
    /// Wave 6 ships the demo catalog as the registry because a consumer's own
    /// scenarios arrive through the Wave 6 Task 3 integration path (building
    /// the consumer's package and loading it), and shipping a CLI that can only
    /// say "no scenarios" would make the whole surface untestable end to end.
    @MainActor
    public static func standard(root: URL = URL(fileURLWithPath: ".")) -> CommandEnvironment {
        CommandEnvironment(
            engine: VerdictEngine(
                registry: DemoScenarios.registry,
                baselines: BaselineStore.standard(root: root)
            ),
            output: StandardOutput()
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
    public init() {}

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let names = environment.engine.scenarioNames
            environment.output.writeOut(try VerdictOutput.json(names, pretty: pretty))
            return .pass
        }
    }
}

// MARK: - render

/// Prints a scenario's semantic tree.
public struct RenderCommand: Sendable {
    public let scenario: String
    public init(scenario: String) { self.scenario = scenario }

    @MainActor
    public func run(_ environment: CommandEnvironment, pretty: Bool) async -> ExitCode {
        await CommandRunner.run(output: environment.output) {
            let tree = try await environment.engine.render(scenario: scenario)
            environment.output.writeOut(try VerdictOutput.json(tree, pretty: pretty))
            return .pass
        }
    }
}

// MARK: - verify

/// Renders a scenario, judges it, and exits on the verdict.
public struct VerifyCommand: Sendable {
    public let scenario: String
    public let useBaseline: Bool
    public let includeTree: Bool

    public init(scenario: String, useBaseline: Bool = false, includeTree: Bool = false) {
        self.scenario = scenario
        self.useBaseline = useBaseline
        self.includeTree = includeTree
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
                includeTree: includeTree
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
