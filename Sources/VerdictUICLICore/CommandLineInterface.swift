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
            List.self, Render.self, Verify.self, Judge.self, Baseline.self, SweepRun.self,
            Inspect.self, Daemon.self, MCP.self,
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

    public struct Inspect: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Read (or press) the UI of a RUNNING app by pid — no adoption needed."
        )
        public init() {}

        @Option(name: .long, help: "Process id of the running application to inspect.")
        public var pid: Int32

        @Option(
            name: .long,
            help: """
                Press the element with this name instead of printing the tree. \
                Names come from the tree above; note they are matched against the \
                RAW accessibility tree (CIS-3DDA018A).
                """)
        public var press: String?

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await InspectCommand(pid: pid, press: press)
                .run(environment, pretty: formatting.pretty)
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

        @Flag(
            name: .long,
            help: """
                Also capture the rendered pixels. The image is written to \
                \(PixelArtifact.directory)/ and its PATH is reported — never the bytes, \
                which would dwarf the tree and cost more than the rest of the payload.
                """
        )
        public var pixels = false

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await RenderCommand(scenario: scenario, pixels: pixels)
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

        // The help text is a single literal because `ArgumentHelp` is
        // `ExpressibleByStringLiteral` — a concatenated expression is a `String`
        // and does not convert, which also breaks the command's synthesized
        // `Decodable` conformance and reports as an unrelated error.
        @Flag(
            name: .long,
            help: """
                Also reconcile against the external accessibility witness. Needs a windowed \
                session and an Accessibility grant on the launching terminal; when it cannot \
                run, the verdict says so rather than passing more quietly.
                """
        )
        public var crossValidate = false

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await VerifyCommand(
                scenario: scenario,
                useBaseline: baseline,
                includeTree: includeTree,
                crossValidate: crossValidate
            ).run(environment, pretty: formatting.pretty, summary: formatting.summary)
            try VerdictUITool.finish(code)
        }
    }

    public struct Judge: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "judge",
            abstract: "Judge a semantic tree you supply — any language, any renderer.",
            discussion: """
                Every other verb renders SwiftUI first, which limits this tool to
                Swift UI. The rule engine never had that limit: it imports only
                Foundation, so it can judge a tree produced by a DOM walk, a
                Flutter semantics dump, a Compose hierarchy or an accessibility
                scrape.

                It does NOT render non-Swift UI. Producing the tree is the
                caller's job; `judge` reads what you send and applies the same
                rules `verify` applies. Exit 1 means the UI failed, exit 2 means
                the tree could not be read — the two are never conflated.

                The tree shape is a JSON `SemanticNode`; see docs/tree-contract.md.
                """
        )
        public init() {}

        @Argument(help: "Path to a JSON semantic tree, or `-` to read stdin.")
        public var tree: String

        @Option(
            name: .long,
            help: "Viewport width in points. Defaults to the root node's own width."
        )
        public var viewportWidth: Double = 0

        @Option(
            name: .long,
            help: "Viewport height in points. Defaults to the root node's own height."
        )
        public var viewportHeight: Double = 0

        @Option(name: .long, help: "Name to file the verdict under.")
        public var name: String = "judged-tree"

        @OptionGroup public var formatting: FormattingOptions

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await JudgeCommand(
                treePath: tree,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                scenarioName: name
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

    /// `verdictui daemon start|stop|status` — the warm socket server.
    public struct Daemon: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "daemon",
            abstract: "Run, stop, or query the warm verification daemon.",
            discussion: """
                A cold `verify` pays process start, package resolution and the
                first SwiftUI warm-up before it renders anything. The daemon
                keeps that cost paid once and answers newline-delimited JSON-RPC
                over a unix socket, so repeat verifies pay only the render.

                It deliberately does NOT accept a baseline update. Every method
                it serves reads the UI; accepting a baseline destroys the record
                of what the UI should be, and a long-running socket-reachable
                process is the wrong place for the single destructive operation
                in this tool. `verdictui baseline --update --accept` stays a
                foreground command a human runs and watches.
                """
        )
        public init() {}

        /// The parser's spelling of ``DaemonCommand/Action``.
        ///
        /// Two enums rather than one because the command layer owns the
        /// behaviour and must stay free of argument-parser types;
        /// `testEveryDaemonActionIsParseable` walks both and fails if either
        /// grows a case the other lacks, so the duplication cannot drift.
        public enum Action: String, ExpressibleByArgument, CaseIterable {
            case start, stop, status

            var command: DaemonCommand.Action {
                switch self {
                case .start: return .start
                case .stop: return .stop
                case .status: return .status
                }
            }
        }

        @Argument(help: "start, stop, or status.")
        public var action: Action = .status

        @Option(name: .long, help: "Socket path. Defaults to ~/.verdictui/daemon.sock.")
        public var socket: String?

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await DaemonCommand(action: action.command, socketPath: socket)
                .run(environment)
            try VerdictUITool.finish(code)
        }
    }

    /// `verdictui mcp` — the stdio MCP server.
    public struct MCP: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "mcp",
            abstract: "Serve the MCP tool catalog over stdio.",
            discussion: """
                Reads newline-delimited JSON-RPC on stdin and writes replies to
                stdout, which is what an MCP client speaks. Diagnostics go to
                stderr — anything else printed to stdout would corrupt the
                protocol stream.

                Every tool routes into the same method surface the CLI and the
                socket daemon use, so the three cannot disagree about what
                `verify` means.
                """
        )
        public init() {}

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await MCPCommand().run(environment)
            try VerdictUITool.finish(code)
        }
    }
}
