import Darwin
import Foundation
import VerdictUIProcessGuardian

/// Owns one process group while retaining its unreaped leader as an identity
/// anchor. A completed leader cannot have its PID recycled before cleanup.
public final class OwnedCommandProcess: @unchecked Sendable {
    public enum Failure: Error { case invalidLaunch, system(Int32), guardianCleanupTimeout, guardianUnavailable }
    public let processIdentifier: pid_t
    private let lock = NSLock()
    private var reaped = false
    private var exitCode: Int32?
    private var retentionFailure: Int32?
    private enum Ownership { case command, guardian(groupReady: Bool), browser }
    private let ownership: Ownership

    private init(pid: pid_t, ownership: Ownership = .command) {
        processIdentifier = pid; self.ownership = ownership
    }

    struct GuardedLaunch {
        let guardian: OwnedCommandProcess
        let browser: OwnedCommandProcess
        let lifetimeWriter: Int32
    }

    static func spawnGuardedBrowser(executable: URL, arguments: [String],
                                    environment: [String: String]) throws -> GuardedLaunch {
        try spawnGuardedCommand(executable: executable, arguments: arguments,
            directory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath), environment: environment)
    }

    /// Internal launch factory, never an arbitrary-PID adoption surface.
    static func spawnGuardedCommand(executable: URL, arguments: [String], directory: URL,
                                    environment: [String: String], standardInput: Int32? = nil,
                                    standardOutput: Int32? = nil, standardError: Int32? = nil) throws -> GuardedLaunch {
        let argv = [executable.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let launchStrings = argv + env + [directory.path]
        guard executable.isFileURL, directory.isFileURL,
              [standardInput, standardOutput, standardError].allSatisfy({ $0 == nil || $0! >= 0 }),
              !launchStrings.contains(where: { $0.contains("\0") }) else {
            throw Failure.invalidLaunch
        }
        let argumentPointers = argv.map { strdup($0) }
        let environmentPointers = env.map { strdup($0) }
        defer { (argumentPointers + environmentPointers).forEach { free($0) } }
        guard argumentPointers.allSatisfy({ $0 != nil }), environmentPointers.allSatisfy({ $0 != nil }) else {
            throw Failure.system(ENOMEM)
        }
        var arguments = argumentPointers + [nil], environment = environmentPointers + [nil]
        var launched = vui_guardian_launch_result()
        let descriptors: [Int32] = [standardInput ?? -1, standardOutput ?? -1, standardError ?? -1]
        let error = executable.path.withCString { executablePath in
            directory.path.withCString { directoryPath in
                vui_guardian_launch(executablePath, &arguments, &environment, directoryPath,
                                    descriptors, 3000, 1000, &launched)
            }
        }
        try checked(error)
        guard launched.guardian_pid > 0, launched.lifetime_fd >= 0 else { throw Failure.invalidLaunch }
        let guardian = OwnedCommandProcess(pid: launched.guardian_pid,
            ownership: .guardian(groupReady: launched.group_ready != 0))
        if launched.error != 0 || launched.group_ready == 0 || launched.browser_pid <= 0 {
            close(launched.lifetime_fd)
            try guardian.finishGuardian(grace: 2)
            throw Failure.system(launched.error == 0 ? EPROTO : launched.error)
        }
        let browser = OwnedCommandProcess(pid: launched.browser_pid, ownership: .browser)
        return GuardedLaunch(guardian: guardian, browser: browser, lifetimeWriter: launched.lifetime_fd)
    }

    /// Checks kernel ownership afresh even after a cached WNOWAIT observation.
    /// ECHILD permanently revokes signal authority; a recycled PID is never used.
    private func confirmRetainedChild() throws {
        if let retentionFailure { throw Failure.system(retentionFailure) }
        guard !reaped else { return }
        _ = try observe(refresh: true)
    }

    /// Normal TERM lets the retained browser coordinate its helpers and flush
    /// storage. This child is retained and rechecked while holding its reap lock;
    /// the public numeric PID is never the authorization for a signal.
    func requestBrowserTermination() throws {
        lock.lock(); defer { lock.unlock() }
        if let retentionFailure { throw Failure.system(retentionFailure) }
        if reaped { return }
        guard case .browser = ownership else { throw Failure.invalidLaunch }
        try confirmRetainedChild()
        if try observe(refresh: true) != nil { return }
        if kill(processIdentifier, SIGTERM) != 0 {
            let failure = errno
            if (failure == ESRCH || failure == EPERM), try observe(refresh: true) != nil { return }
            throw Failure.system(failure)
        }
    }

    /// Guardian and browser cleanup use bounded waits, including destruction.
    /// Before READY no browser has been spawned, so direct-child KILL is safe.
    func finishGuardian(grace: TimeInterval = 0) throws {
        lock.lock(); defer { lock.unlock() }
        if let retentionFailure { throw Failure.system(retentionFailure) }
        if reaped { return }
        guard case .guardian(let groupReady) = ownership else { throw Failure.invalidLaunch }
        try confirmRetainedChild()
        if grace > 0 { _ = try waitForRetainedExit(timeout: grace) }
        try confirmRetainedChild()
        if groupReady {
            // READY validated this group in the factory. Darwin can stop
            // answering getpgid for its unreaped zombie; WNOWAIT retains the
            // established identity until every descendant has stopped.
            try signalGroup(SIGKILL)
        } else if kill(processIdentifier, SIGKILL) != 0 && errno != ESRCH {
            throw Failure.system(errno)
        }
        guard try waitForRetainedExit(timeout: 5) else { throw Failure.guardianCleanupTimeout }
        let deadline = ContinuousClock.now + .seconds(2)
        while groupReady && !groupHasOnlyExitedMembers() {
            guard ContinuousClock.now < deadline else { throw Failure.guardianCleanupTimeout }
            Thread.sleep(forTimeInterval: 0.01) // verdictui-os-cleanup:group-quiescence
        }
        try reapRetainedChild()
    }

    /// Called only after the guardian proved no active group members remain.
    func finishBrowser() throws {
        lock.lock(); defer { lock.unlock() }
        if let retentionFailure { throw Failure.system(retentionFailure) }
        if reaped { return }
        guard case .browser = ownership else { throw Failure.invalidLaunch }
        try confirmRetainedChild()
        guard try waitForRetainedExit(timeout: 5) else { throw Failure.guardianCleanupTimeout }
        try reapRetainedChild()
    }

    private func waitForRetainedExit(timeout: TimeInterval) throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        repeat {
            if try observe() != nil { return true }
            // A process-exit event can precede waitid's exit record on Darwin.
            // Retained-child cleanup needs the record, not only the event.
            Thread.sleep(forTimeInterval: 0.01) // verdictui-os-cleanup:waitid-readiness
        } while ContinuousClock.now < deadline
        return try observe() != nil
    }

    private func reapRetainedChild() throws {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(processIdentifier, &status, WNOHANG) } while result < 0 && errno == EINTR
        guard result == processIdentifier else { throw Failure.system(result == 0 ? EBUSY : errno) }
        reaped = true
    }

    public static func spawn(executable: URL, arguments: [String], directory: URL,
                      environment: [String: String], standardInput: Int32? = nil,
                      standardOutput: Int32? = nil, standardError: Int32? = nil) throws -> OwnedCommandProcess {
        let argv = [executable.path] + arguments
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        guard executable.isFileURL, directory.isFileURL,
              !(argv + env + [directory.path]).contains(where: { $0.contains("\0") }) else { throw Failure.invalidLaunch }
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(addWorkingDirectory(&actions, path: directory.path))
        for (source, destination) in [(standardInput, STDIN_FILENO), (standardOutput, STDOUT_FILENO), (standardError, STDERR_FILENO)] {
            if let source { try checked(posix_spawn_file_actions_adddup2(&actions, source, destination)) }
            else { try checked(posix_spawn_file_actions_addopen(&actions, destination, "/dev/null", O_RDWR, 0)) }
        }
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var signals = sigset_t()
        sigemptyset(&signals)
        for number in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&signals, number) }
        try checked(posix_spawnattr_setsigdefault(&attributes, &signals))
        var mask = sigset_t()
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        try checked(posix_spawnattr_setflags(&attributes, Int16(flags)))
        let argumentPointers = argv.map { strdup($0) }
        let environmentPointers = env.map { strdup($0) }
        defer { (argumentPointers + environmentPointers).forEach { free($0) } }
        guard argumentPointers.allSatisfy({ $0 != nil }), environmentPointers.allSatisfy({ $0 != nil }) else { throw Failure.system(ENOMEM) }
        var argumentVector = argumentPointers + [nil]
        var environmentVector = environmentPointers + [nil]
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, executable.path, &actions, &attributes, &argumentVector, &environmentVector))
        return OwnedCommandProcess(pid: pid)
    }

    /// Nil means running; observing exit never reaps the identity anchor.
    public func status() throws -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return try observe()
    }

    /// Waits for the retained child's exit without reaping its identity anchor.
    /// The event source is cancelled on both delivery and timeout. A concurrent
    /// stop waits for this bounded observation to finish before it can reap.
    public func waitForExitEvent(timeout: TimeInterval) -> Bool {
        guard timeout.isFinite, timeout >= 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return waitForExitWhileLocked(timeout: timeout)
    }

    private func waitForExitWhileLocked(timeout: TimeInterval) -> Bool {
        if (try? observe()) != nil { return true }
        guard !reaped, timeout > 0 else { return false }
        let completion = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier,
            eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { completion.signal() }
        source.activate()
        defer { source.cancel() }
        // Cover exit between the first observation and event registration.
        if (try? observe()) != nil { return true }
        _ = completion.wait(timeout: .now() + timeout)
        return (try? observe()) != nil
    }

    @discardableResult
    public func stop(grace: TimeInterval = 1) throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if reaped { return exitCode ?? 128 + SIGKILL }
        var observed = try observe()
        try signalGroup(SIGTERM)
        if observed == nil && grace.isFinite && grace > 0 {
            _ = waitForExitWhileLocked(timeout: grace)
            observed = try observe()
        }
        // The leader is still unreaped, even if it already exited. Kill any
        // remaining descendants before releasing that unique group identity.
        try signalGroup(SIGKILL)
        var rawStatus: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(processIdentifier, &rawStatus, 0) } while result == -1 && errno == EINTR
        guard result == processIdentifier else { reaped = true; throw Failure.system(errno) }
        reaped = true
        let code = observed ?? ((rawStatus & 0x7f) == 0 ? (rawStatus >> 8) & 0xff : 128 + (rawStatus & 0x7f))
        exitCode = code
        return code
    }

    private func observe(refresh: Bool = false) throws -> Int32? {
        if reaped || (exitCode != nil && !refresh) { return exitCode }
        var info = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT) } while result == -1 && errno == EINTR
        guard result == 0 else {
            // If another owner reaped the child, it is no longer safe to signal
            // this numeric process group. Refuse instead of guessing ownership.
            if errno == ECHILD { reaped = true; retentionFailure = ECHILD }
            throw Failure.system(errno)
        }
        guard info.si_pid == processIdentifier else { return nil }
        exitCode = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
        return exitCode
    }

    private func signalGroup(_ number: Int32) throws {
        guard !reaped else { return }
        guard kill(-processIdentifier, number) != 0 else { return }
        let failure = errno
        if failure == ESRCH { return }
        // Darwin returns EPERM for a group containing only zombies, including
        // our deliberately unreaped anchor. Verify members before accepting it.
        if failure == EPERM && groupHasOnlyExitedMembers() { return }
        throw Failure.system(failure)
    }

    private func groupHasOnlyExitedMembers() -> Bool {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), nil, 0)
        guard bytes > 0 else { return false }
        var members = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let capacity = Int32(members.count * MemoryLayout<pid_t>.size)
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(processIdentifier), &members, capacity)
        guard count > 0 && count < capacity else { return false }
        for member in members.prefix(Int(count) / MemoryLayout<pid_t>.size) where member > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            errno = 0
            let read = proc_pidinfo(member, PROC_PIDTBSDINFO, 0, &info, size)
            if read == 0 && errno == ESRCH { continue }
            guard read == size else { return false }
            if info.pbi_pgid == UInt32(processIdentifier) && info.pbi_status != UInt32(SZOMB) { return false }
        }
        return true
    }

    private static func addWorkingDirectory(_ actions: inout posix_spawn_file_actions_t?, path: String) -> Int32 {
        // Xcode 26 pairs Swift 6.2 with the first SDK declaring the POSIX name.
        // A runtime availability check alone cannot compile against older SDKs.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return posix_spawn_file_actions_addchdir(&actions, path)
        } else {
            return posix_spawn_file_actions_addchdir_np(&actions, path)
        }
        #else
        return posix_spawn_file_actions_addchdir_np(&actions, path)
        #endif
    }

    private static func checked(_ result: Int32) throws {
        guard result == 0 else { throw Failure.system(result) }
    }

    deinit {
        switch ownership {
        case .command: _ = try? stop(grace: 0)
        case .guardian: try? finishGuardian()
        case .browser: try? finishBrowser()
        }
    }
}
