import ArgumentParser
import Foundation

extension VerdictUITool {
    public struct Live: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "live",
            abstract: "Inspect, verify or act on a real macOS app and observe its resulting state."
        )
        public init() {}

        public enum Operation: String, ExpressibleByArgument, Sendable {
            case inspect, verify, act
        }
        @Argument public var operation: Operation
        @Option public var pid: Int32?
        @Option public var app: String?
        @Option public var surface = "window:0"
        @Option public var path: String?
        @Option public var action: String?
        @Option public var value: String?
        @Option(name: .long) public var expectText: String?
        @Option public var timeout = 5.0
        @Flag public var pretty = false

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let response = await VerdictDaemon.handle(
                DaemonRequest(method: "live_" + operation.rawValue, live: LiveRequest(
                    pid: pid, app: app, surface: surface, path: path, action: action,
                    value: value, expectText: expectText, timeout: timeout
                )), engine: environment.engine
            )
            try VerdictUITool.finish(try ExternalCommandOutput.write(
                response, environment: environment, pretty: pretty
            ))
        }
    }
}

/// Shared 0/1/2 mapping for external-product commands.
enum ExternalCommandOutput {
    static func write(
        _ response: DaemonResponse, environment: CommandEnvironment, pretty: Bool
    ) throws -> ExitCode {
        guard response.ok, let result = response.result else {
            environment.output.writeError((response.error ?? "no result") + "\n")
            environment.output.writeOut(try VerdictOutput.json(response, pretty: pretty))
            return .couldNotVerify
        }
        switch result {
        case .webSessions(let sessions):
            environment.output.writeOut(try VerdictOutput.json(sessions, pretty: pretty))
            return .pass
        case .tree(let tree):
            environment.output.writeOut(try VerdictOutput.json(tree, pretty: pretty))
            return .pass
        case .verdict(let verdict):
            environment.output.writeOut(try VerdictOutput.json(verdict, pretty: pretty))
            return verdict.status == .pass ? .pass : .verdictFailed
        case .step(let step):
            environment.output.writeOut(try VerdictOutput.json(step, pretty: pretty))
            return step.status == "PASS" ? .pass : .verdictFailed
        default:
            environment.output.writeOut(try VerdictOutput.json(response, pretty: pretty))
            return .pass
        }
    }
}
