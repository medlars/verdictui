import Darwin
import Foundation

/// The exit source captures only this fd owner, never the process object.
private final class ProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: Int32
    init(_ writer: Int32) { self.writer = writer }
    func closeWriter() {
        lock.lock(); defer { lock.unlock() }
        if writer >= 0 { close(writer); writer = -1 }
    }
    deinit { closeWriter() }
}

/// A launch-owned command and its crash guardian. The public PID and exit code
/// describe the command; only retained child identities authorize termination.
/// Inherited groups are contained, including after the launching host dies.
/// A command deliberately creating another session/group is outside this contract.
public final class GuardedProcess: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let guardian: OwnedCommandProcess
    private let child: OwnedCommandProcess
    private let lifetime: ProcessLifetime
    private let exitSource: DispatchSourceProcess
    public let processIdentifier: pid_t
    private var completedCode: Int32?

    private init(_ launch: OwnedCommandProcess.GuardedLaunch) {
        guardian = launch.guardian; child = launch.browser
        processIdentifier = child.processIdentifier
        lifetime = ProcessLifetime(launch.lifetimeWriter)
        exitSource = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit,
                                                       queue: .global(qos: .utility))
        let lifetime = self.lifetime
        exitSource.setEventHandler { lifetime.closeWriter() }
        exitSource.activate()
        // Cover command exit before/during registration without reaping it.
        do { if try child.status() != nil { lifetime.closeWriter() } }
        catch { lifetime.closeWriter() }
    }

    public static func spawn(executable: URL, arguments: [String], directory: URL,
                             environment: [String: String], standardInput: Int32? = nil,
                             standardOutput: Int32? = nil, standardError: Int32? = nil) throws -> GuardedProcess {
        GuardedProcess(try OwnedCommandProcess.spawnGuardedCommand(executable: executable,
            arguments: arguments, directory: directory, environment: environment,
            standardInput: standardInput, standardOutput: standardOutput, standardError: standardError))
    }

    /// Nil means the actual command is running with its guardian still available.
    /// Observing exit does not reap either retained identity.
    public func status() throws -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if let completedCode { return completedCode }
        let code = try child.status()
        if code != nil { lifetime.closeWriter(); return code }
        guard try guardian.status() == nil else {
            lifetime.closeWriter()
            throw OwnedCommandProcess.Failure.guardianUnavailable
        }
        return nil
    }

    public func waitForExitEvent(timeout: TimeInterval) -> Bool {
        child.waitForExitEvent(timeout: timeout)
    }

    /// Normal TERM targets only the retained command, so it can coordinate its
    /// helpers and flush state. The guardian remains alive for the caller's grace.
    public func requestTermination() throws {
        lock.lock(); defer { lock.unlock() }
        if completedCode != nil { return }
        try child.requestBrowserTermination()
    }

    @discardableResult
    public func stop(grace: TimeInterval = 1) throws -> Int32 {
        guard grace.isFinite, grace >= 0 else { throw OwnedCommandProcess.Failure.invalidLaunch }
        lock.lock(); defer { lock.unlock() }
        if let completedCode { return completedCode }
        try requestTermination()
        if grace > 0 { _ = child.waitForExitEvent(timeout: grace) }
        return try finish(grace: 0)
    }

    /// Group completion precedes child reaping and caller resource release.
    /// Retain both owners after a cleanup failure so callers can remain unavailable.
    @discardableResult
    func finish(grace: TimeInterval) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let completedCode { return completedCode }
        lifetime.closeWriter()
        exitSource.cancel()
        try guardian.finishGuardian(grace: grace)
        try child.finishBrowser()
        guard let code = try child.status() else { throw OwnedCommandProcess.Failure.guardianCleanupTimeout }
        completedCode = code
        return code
    }

    deinit { _ = try? finish(grace: 0) }
}
