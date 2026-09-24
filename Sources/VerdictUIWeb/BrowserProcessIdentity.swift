import Darwin
import Foundation

/// A process identity bound to the child we launched. A PID alone can be
/// recycled after exit and is never sufficient authority to signal a process.
protocol BrowserProcessIdentity: Sendable {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    func signal(_ value: Int32) throws
    func finish() throws
}

extension BrowserProcessIdentity {
    func finish() throws {}
}

/// Browser-specific interface over the shared command lifetime owner.
final class LaunchedBrowserProcess: BrowserProcessIdentity, @unchecked Sendable {
    private let process: GuardedProcess
    var pid: pid_t { process.processIdentifier }

    private init(_ process: GuardedProcess) { self.process = process }

    static func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> LaunchedBrowserProcess {
        LaunchedBrowserProcess(try GuardedProcess.spawn(executable: executable,
            arguments: arguments, directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: environment))
    }

    var isRunning: Bool {
        do { return try process.status() == nil } catch { return false }
    }

    func signal(_ value: Int32) throws {
        if value == SIGTERM { try process.requestTermination() }
        else if value == SIGKILL { try process.finish(grace: 0) }
        else { throw OwnedCommandProcess.Failure.invalidLaunch }
    }

    func finish() throws { try process.finish(grace: 2) }
}
