// Wave 6: the argument-parser declarations.
//
// Kept in the LIBRARY rather than in the executable so a test can construct and
// run any of them. `main.swift` is four lines and holds no behaviour.
import ArgumentParser
import Foundation
import VerdictUIKernel

/// `verdictui` — verify SwiftUI scenarios and print machine-readable verdicts.
///
/// The availability attribute is REQUIRED, not decorative: argument-parser
/// dispatches an async root command through a runtime path that refuses to
/// start without one, and it refuses at RUN time with a message about
/// annotations rather than at compile time. The whole library test suite passed
/// against a binary that could not execute a single command — the exact shape
/// `no.md` #277 records, where a green suite says nothing about the artifact
/// that ships. `CLIBinarySmokeTests` now runs the built binary for that reason.
@available(macOS 13, *)
public struct VerdictUITool: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "verdictui",
        abstract: "Verify SwiftUI scenarios and print a verdict an agent can parse.",
        discussion: """
            Every command writes one complete JSON document to stdout and nothing
            else; diagnostics go to stderr. Exit codes are three-valued:

              0  the verdict passed, or the query succeeded
              1  a verdict was produced and it FAILED — the UI is wrong
              2  no verdict could be produced — says nothing about the UI

            The distinction between 1 and 2 is deliberate. A tool that reports
            "not passing" for both an incorrect layout and an unreadable
            scenario forces callers to treat infrastructure faults as product
            defects.
            """,
        version: SchemaVersion.current,
        subcommands: [
            List.self, Render.self, Verify.self, Baseline.self, SweepRun.self,
        ],
        defaultSubcommand: List.self
    )

    public init() {}

    /// Runs `body` and terminates with its exit code.
    ///
    /// `ExitCode.pass` returns normally so argument-parser's own success path
    /// runs; anything else throws its code. Routing every subcommand through
    /// one helper is what keeps the code mapping in a single place.
    @MainActor
    static func finish(_ code: ExitCode) throws {
        guard code != .pass else { return }
        throw ArgumentParser.ExitCode(code.rawValue)
    }

    // MARK: - Subcommands

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List every scenario this tool can run."
        )
        public init() {}

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await ListCommand().run(environment, pretty: formatting.pretty)
            try VerdictUITool.finish(code)
        }
    }

    public struct Render: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "render",
            abstract: "Print a scenario's semantic tree."
        )
        public init() {}

        @Argument(help: "Scenario name, as printed by `verdictui list`.")
        public var scenario: String

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await RenderCommand(scenario: scenario)
                .run(environment, pretty: formatting.pretty)
            try VerdictUITool.finish(code)
        }
    }

    public struct Verify: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Render a scenario, judge it, and exit on the verdict."
        )
        public init() {}

        @Argument(help: "Scenario name, as printed by `verdictui list`.")
        public var scenario: String

        @Flag(name: .long, help: "Also compare against the recorded baseline.")
        public var baseline = false

        @Flag(name: .long, help: "Embed the semantic tree in the verdict.")
        public var includeTree = false

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await VerifyCommand(
                scenario: scenario,
                useBaseline: baseline,
                includeTree: includeTree
            ).run(environment, pretty: formatting.pretty, summary: formatting.summary)
            try VerdictUITool.finish(code)
        }
    }

    public struct Baseline: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "baseline",
            abstract: "Show or accept baseline drift.",
            discussion: """
                `baseline update` REPLACES the record of what a screen should
                look like, so it refuses without --accept once a baseline
                exists, prints the delta it is about to accept, and logs the
                superseded content's hash to logs/baseline-audit.log.
                """
        )
        public init() {}

        @Argument(help: "Scenario name.")
        public var scenario: String

        @Flag(name: .long, help: "Record the current render as the new baseline.")
        public var update = false

        @Flag(name: .long, help: "Confirm a destructive baseline replacement.")
        public var accept = false

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let mode: BaselineCommand.Mode = update ? .update(accepted: accept) : .diff
            let code = await BaselineCommand(scenario: scenario, mode: mode)
                .run(environment, pretty: formatting.pretty)
            try VerdictUITool.finish(code)
        }
    }

    public struct SweepRun: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "sweep",
            abstract: "Render a scenario across a variant matrix."
        )
        public init() {}

        @Argument(help: "Scenario name.")
        public var scenario: String

        @Option(
            name: .long,
            parsing: .upToNextOption,
            help: "Locale identifiers, e.g. en_US de_DE ar_SA."
        )
        public var locales: [String] = []

        @Option(name: .long, parsing: .upToNextOption, help: "light and/or dark.")
        public var colorSchemes: [String] = []

        @Option(
            name: .long,
            parsing: .upToNextOption,
            help: "Dynamic type sizes, e.g. medium accessibility3."
        )
        public var dynamicTypeSizes: [String] = []

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await SweepCommand(
                scenario: scenario,
                locales: locales,
                colorSchemes: colorSchemes,
                dynamicTypeSizes: dynamicTypeSizes
            ).run(environment, pretty: formatting.pretty)
            try VerdictUITool.finish(code)
        }
    }
}
