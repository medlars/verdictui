import Darwin
import Foundation

/// A process identity bound to the child we launched. A PID alone can be
/// recycled after exit and is never sufficient authority to signal a process.
protocol BrowserProcessIdentity: Sendable {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    func signal(_ value: Int32)
}

struct LaunchedBrowserProcess: BrowserProcessIdentity {
    let process: Process
    var pid: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    func signal(_ value: Int32) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, value)
    }
}
