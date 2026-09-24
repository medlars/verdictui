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

/// The process source captures only this fd owner, never the browser object.
/// Closing is idempotent under concurrent exit delivery and explicit shutdown.
private final class BrowserLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: Int32
    init(_ writer: Int32) { self.writer = writer }
    func closeWriter() {
        lock.lock(); defer { lock.unlock() }
        if writer >= 0 { close(writer); writer = -1 }
    }
    deinit { closeWriter() }
}

final class LaunchedBrowserProcess: BrowserProcessIdentity, @unchecked Sendable {
    private let guardian: OwnedCommandProcess
    private let browser: OwnedCommandProcess
    private let lifetime: BrowserLifetime
    private let exitSource: DispatchSourceProcess
    let pid: pid_t

    private init(_ launch: OwnedCommandProcess.GuardedLaunch) {
        guardian = launch.guardian; browser = launch.browser
        pid = browser.processIdentifier
        lifetime = BrowserLifetime(launch.lifetimeWriter)
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                       queue: .global(qos: .utility))
        let lifetime = self.lifetime
        exitSource.setEventHandler { lifetime.closeWriter() }
        exitSource.activate()
        // Cover browser exit before or during registration, without reaping it.
        if !isRunning { lifetime.closeWriter() }
    }

    static func launch(executable: URL, arguments: [String], environment: [String: String]) throws -> LaunchedBrowserProcess {
        LaunchedBrowserProcess(try OwnedCommandProcess.spawnGuardedBrowser(executable: executable,
            arguments: arguments, environment: environment))
    }

    var isRunning: Bool {
        do { return try browser.status() == nil && guardian.status() == nil }
        catch { lifetime.closeWriter(); return false }
    }

    func signal(_ value: Int32) throws {
        lifetime.closeWriter()
        if value == SIGKILL { try finish(grace: 0) }
    }

    private func finish(grace: TimeInterval) throws {
        lifetime.closeWriter()
        exitSource.cancel()
        // Group completion precedes both reaping the browser and releasing its
        // profile lock in the caller. Guardian exit alone does not prove this.
        try guardian.finishGuardian(grace: grace)
        try browser.finishBrowser()
    }

    func finish() throws { try finish(grace: 2) }

    deinit { try? finish(grace: 0) }
}
