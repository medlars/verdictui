// Wave 7: the commands that start the two transports.
//
// Thin by design — each parses an intent and hands off to a transport. The
// interesting decisions (framing, dispatch, what `isError` means) live in
// `DaemonTransport` and `MCPTransport`; the interesting decisions about what a
// method MEANS live in `VerdictDaemon`. This file only starts things.
import ArgumentParser
import Foundation
import VerdictUIKernel

// MARK: - daemon

/// Starts, stops, or reports on the socket daemon.
@available(macOS 13, *)
public struct DaemonCommand: Sendable {
    /// What the caller asked for.
    ///
    /// Declared HERE rather than on the argument-parser subcommand, and the
    /// parser's own type conforms to `ExpressibleByArgument` and maps onto this
    /// one. The command layer is the layer with the behaviour, so it owns its
    /// vocabulary; taking the parser's enum instead would make this `Sendable`
    /// struct hold a non-`Sendable` argument-parser type, and would point the
    /// dependency arrow at the layer that is supposed to be replaceable.
    public enum Action: String, Sendable, CaseIterable {
        case start, stop, status
    }

    private let action: Action
    private let socketPath: String?

    public init(action: Action, socketPath: String?) {
        self.action = action
        self.socketPath = socketPath
    }

    @MainActor
    public func run(_ environment: CommandEnvironment) async -> ExitCode {
        let path = socketPath ?? VerdictDaemon.defaultSocketPath

        switch action {
        case .status:
            return status(environment, path: path)
        case .stop:
            return stop(environment, path: path)
        case .start:
            return await start(environment, path: path)
        }
    }

    /// Report whether a daemon is actually listening.
    ///
    /// Probed by CONNECTING, never by checking the socket file exists: a daemon
    /// killed without unwinding leaves its socket behind, and a status command
    /// that read the filesystem would report a dead daemon as running for as
    /// long as that file survived it.
    @MainActor
    private func status(_ environment: CommandEnvironment, path: String) -> ExitCode {
        let live = DaemonTransport.isLive(path: path)
        let report = DaemonStatus(running: live, socket: path)
        guard let json = try? VerdictOutput.json(report, pretty: false) else {
            environment.output.writeError("verdictui: could not encode daemon status\n")
            return .couldNotVerify
        }
        environment.output.writeOut(json)
        return .pass
    }

    /// Stop a running daemon by removing its socket.
    ///
    /// Reported honestly: stopping a daemon that was not running is not an
    /// error — it is the state the caller asked for — but it must not claim to
    /// have stopped something.
    @MainActor
    private func stop(_ environment: CommandEnvironment, path: String) -> ExitCode {
        guard DaemonTransport.isLive(path: path) else {
            environment.output.writeError("verdictui: no daemon listening on \(path)\n")
            return .pass
        }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            environment.output.writeError("verdictui: could not remove \(path): \(error)\n")
            return .couldNotVerify
        }
        environment.output.writeError("verdictui: daemon socket at \(path) removed\n")
        return .pass
    }

    /// Bind and serve until the process is stopped.
    ///
    /// The readiness line goes to STDERR, not stdout. Every other command in
    /// this tool writes exactly one JSON document to stdout and nothing else,
    /// and a client that pipes the daemon's stdout would otherwise have to
    /// tolerate a stray banner in front of the stream.
    @MainActor
    private func start(_ environment: CommandEnvironment, path: String) async -> ExitCode {
        let transport = DaemonTransport(engine: environment.engine, socketPath: path)
        do {
            environment.output.writeError("verdictui: daemon listening on \(path)\n")
            try await transport.serve()
            return .pass
        } catch let error as DaemonTransport.TransportError {
            environment.output.writeError("verdictui: \(error.description)\n")
            return .couldNotVerify
        } catch {
            environment.output.writeError("verdictui: daemon failed: \(error)\n")
            return .couldNotVerify
        }
    }
}

/// What `daemon status` prints.
public struct DaemonStatus: Codable, Sendable, Equatable {
    /// Whether something answered on the socket just now.
    public let running: Bool
    public let socket: String

    public init(running: Bool, socket: String) {
        self.running = running
        self.socket = socket
    }
}

// MARK: - mcp

/// Serves the MCP tool catalog over stdio until stdin closes.
@available(macOS 13, *)
public struct MCPCommand: Sendable {
    public init() {}

    @MainActor
    public func run(_ environment: CommandEnvironment) async -> ExitCode {
        let transport = MCPTransport(engine: environment.engine)
        await transport.serve(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput
        )
        return .pass
    }
}
