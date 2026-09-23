import ArgumentParser
import Foundation

extension VerdictUITool {
    public struct Web: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "web",
            abstract: "Drive and verify real websites in an isolated headless browser.",
            discussion: "Browser sessions persist in the daemon. Use web close --profile NAME when finished, or daemon stop to close all sessions."
        )
        public init() {}
        public enum Operation: String, ExpressibleByArgument, Sendable {
            case list, open, render, verify, act, close
        }
        @Argument public var operation: Operation
        @Argument(help: "URL for open or verify; file:// fixtures are supported.") public var url: String?
        @Option public var profile = "default"
        @Option public var node: String?
        @Option public var action: String?
        @Option public var text: String?
        @Option(help: "Credential name or op:// reference; never a password.") public var credential: String?
        @Option public var key: String?
        @Option(help: "Comma-separated key modifiers.") public var modifiers: String?
        @Option(name: .long) public var expectText: String?
        @Option public var socket: String?
        @Flag public var pretty = false

        @MainActor
        public func run() async throws {
            let environment = CommandEnvironment.standard()
            let code = await CommandRunner.run(output: environment.output) {
                let path = socket ?? environment.daemonSocketPath
                let request = WebRequest(
                    profile: profile, url: url, action: action, node: node, text: text,
                    credential: credential, key: key, modifiers: modifiers, expectText: expectText
                )
                // Refuse malformed action data before starting any process.
                if operation == .act { _ = try WebRuntime.action(request) }
                try await DaemonClient.ensureRunning(
                    socketPath: path,
                    executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
                    stock: environment.usesFallbackCatalog
                )
                if operation == .verify, url != nil {
                    let opened = try await DaemonClient.send(DaemonRequest(method: "web_open", web: request), socketPath: path)
                    guard opened.ok else {
                        return try ExternalCommandOutput.write(opened, environment: environment, pretty: pretty)
                    }
                }
                let response = try await DaemonClient.send(
                    DaemonRequest(method: "web_" + operation.rawValue, web: request), socketPath: path
                )
                return try ExternalCommandOutput.write(response, environment: environment, pretty: pretty)
            }
            try VerdictUITool.finish(code)
        }
    }
}
