import Foundation
import VerdictUIKernel

/// `verdictui appkit` — judge an AppKit screen with no snapshot and no Automator.
///
/// WHY THIS EXISTS. Before it, an AppKit product had no way in. `inspect --pid`
/// resolves its coordinate anchor from an `AXGroup` child that only a SwiftUI
/// hosting view publishes, so it exits 2 on a pure-AppKit app (CIS-C5D9A5E8);
/// and `verdictProbe` is `extension View`, i.e. SwiftUI only. That left
/// screenshots and UI automation — the two things this command removes.
///
/// WHY IT DRIVES A CONSUMER-BUILT RUNNER rather than loading views itself: an
/// `NSView` subclass exists only in the binary that compiled it. It cannot cross
/// a process boundary, be rebuilt from JSON, or be `dlopen`ed without binding
/// the installed CLI to the consumer's exact toolchain. So the consumer compiles
/// a few-line executable that links `VerdictUIAppKit` and names its screens, and
/// this command runs it and judges what it prints. No plugin ABI, no version
/// handshake — the same shape `ProjectScenarios` already uses for SwiftUI.
///
/// This does NOT contradict ADR 2026-025 ("judge takes a tree rather than
/// rendering foreign UI"). That ADR draws its line at NON-SWIFT UI — a DOM walk,
/// a Flutter semantics dump — and AppKit is Swift. `appkit` is a first-party
/// PRODUCER feeding the same `judge` pipeline, not a second rule engine. Worth
/// stating here because the ADR names this file, so the next reader arrives with
/// exactly that question.
public struct AppKitCommand: Sendable {
    /// Path to the consumer's runner executable.
    public let runner: String
    /// Subject to render. `nil` asks the runner to list what it has.
    public let subject: String?
    /// Judge the tree rather than only printing it.
    public let judge: Bool
    public let viewportWidth: Double
    public let viewportHeight: Double

    public init(
        runner: String,
        subject: String?,
        judge: Bool,
        viewportWidth: Double = 0,
        viewportHeight: Double = 0
    ) {
        self.runner = runner
        self.subject = subject
        self.judge = judge
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }

    /// What running the consumer's runner produced.
    ///
    /// `failed` is deliberately NOT an `ExitCode`: every failure here means the
    /// runner could not be executed or did not emit a tree, which is
    /// `couldNotVerify` at the CLI boundary. Keeping the distinction in the type
    /// stops a later edit from accidentally mapping "your runner is missing" to
    /// "your UI is wrong".
    enum RunnerOutcome {
        case produced(String)
        case failed(String)
    }

    /// Execute the runner and capture stdout.
    ///
    /// Static and injectable-free so a test can exercise it against a shell
    /// script standing in for a real consumer binary — spawning a process is the
    /// behaviour under test here, so faking it away would test nothing.
    static func invoke(runner: String, arguments: [String]) -> RunnerOutcome {
        let executable = URL(fileURLWithPath: runner)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failed("runner is not an executable file: \(runner)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return .failed("could not launch runner \(runner): \(error)")
        }
        // Read BEFORE waiting: a runner whose tree exceeds the pipe buffer would
        // block writing while we block waiting, and the command would hang
        // forever on exactly the large trees it exists to handle.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failed(
                "runner exited \(process.terminationStatus)"
                    + (detail.isEmpty ? "" : ": \(detail)"))
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return .failed("runner produced no output")
        }
        return .produced(text)
    }

    /// - Parameter summary: print the human rendering instead of JSON, as every
    ///   other verdict-producing verb does. It was accepted at the flag layer
    ///   and silently ignored here, which is the worst shape a flag can take: a
    ///   developer asking for a summary got JSON and had no signal that the flag
    ///   had done nothing.
    @MainActor
    public func run(
        _ environment: CommandEnvironment,
        pretty: Bool,
        summary: Bool = false
    ) async -> ExitCode {
        guard let subject else {
            switch Self.invoke(runner: runner, arguments: ["list"]) {
            case .produced(let text):
                environment.output.writeOut(text)
                return .pass
            case .failed(let reason):
                environment.output.writeError("verdictui: \(reason)\n")
                return .couldNotVerify
            }
        }

        let text: String
        switch Self.invoke(runner: runner, arguments: ["render", subject]) {
        case .produced(let produced):
            text = produced
        case .failed(let reason):
            environment.output.writeError("verdictui: \(reason)\n")
            return .couldNotVerify
        }

        let tree: SemanticNode
        do {
            tree = try JSONDecoder().decode(SemanticNode.self, from: Data(text.utf8))
        } catch {
            // A runner that printed something unparseable told us nothing about
            // the UI, so this is a 2 — never a failed verdict.
            environment.output.writeError(
                "verdictui: runner output is not a semantic tree: \(error)\n")
            return .couldNotVerify
        }

        guard judge else {
            do {
                environment.output.writeOut(try VerdictOutput.json(tree, pretty: pretty))
                return .pass
            } catch {
                environment.output.writeError("verdictui: could not encode tree: \(error)\n")
                return .couldNotVerify
            }
        }

        let verdict = JudgeCommand.judge(
            tree: tree,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            scenarioName: subject
        )
        do {
            environment.output.writeOut(
                summary
                    ? VerdictOutput.humanReadable(verdict)
                    : try VerdictOutput.json(verdict, pretty: pretty)
            )
        } catch {
            environment.output.writeError("verdictui: could not encode verdict: \(error)\n")
            return .couldNotVerify
        }
        return verdict.status == .pass ? .pass : .verdictFailed
    }
}
